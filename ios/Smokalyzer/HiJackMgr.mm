//
//  HiJackMgr.m
//  HiJack
//
//  Created by Thomas Schmid on 8/4/11.
//

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>

#import "HiJackMgr.h"
#import "AudioUnit/AudioUnit.h"
#import "CAXException.h"
#import "aurio_helper.h"

// threshold used to detect start bit
#define THRESHOLD 0 

// baud rate. best to take a divisible number for 44.1kS/s
#define HIGHFREQ 1378.125 
#define LOWFREQ (HIGHFREQ / 2)

// (44100 / HIGHFREQ)  // how many samples per UART bit
#define SAMPLESPERBIT 32 

#define SHORT (SAMPLESPERBIT/2 + SAMPLESPERBIT/4)
#define LONG (SAMPLESPERBIT + SAMPLESPERBIT/2)

// number of stop bits to send before sending next value.
#define NUMSTOPBITS 100 

#define AMPLITUDE (1<<24)

enum uart_state {
	STARTBIT = 0,
	SAMEBIT  = 1,
	NEXTBIT  = 2,
	STOPBIT  = 3,
	STARTBIT_FALL = 4,
	DECODE   = 5,
};

@implementation HiJackMgr

@synthesize rioUnit;
@synthesize inputProc;
@synthesize unitIsRunning;
@synthesize uartByteTransmit;
@synthesize maxFPS;
@synthesize newByte;

#pragma mark -Audio Session Interruption Listener

void rioInterruptionListener(void *inClientData, UInt32 inInterruption)
{
	printf("Session interrupted! --- %s ---", inInterruption == kAudioSessionBeginInterruption ? "Begin Interruption" : "End Interruption");
	
	HiJackMgr *THIS = (HiJackMgr*)inClientData;
	
	if (inInterruption == kAudioSessionEndInterruption) {
		// make sure we are again the active session
		AudioSessionSetActive(true);
		AudioOutputUnitStart(THIS->rioUnit);
	}
	
	if (inInterruption == kAudioSessionBeginInterruption) {
		AudioOutputUnitStop(THIS->rioUnit);
    }
}

#pragma mark -Audio Session Property Listener

void propListener(	void *                  inClientData,
				  AudioSessionPropertyID	inID,
				  UInt32                  inDataSize,
				  const void *            inData)
{
	HiJackMgr*THIS = (HiJackMgr*)inClientData;
	
	if (inID == kAudioSessionProperty_AudioRouteChange)
	{
		try {
			// if there was a route change, we need to dispose the current rio unit and create a new one
			XThrowIfError(AudioComponentInstanceDispose(THIS->rioUnit), "couldn't dispose remote i/o unit");		
			
			SetupRemoteIO(THIS->rioUnit, THIS->inputProc, THIS->thruFormat);
			
			UInt32 size = sizeof(THIS->hwSampleRate);
			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &THIS->hwSampleRate), "couldn't get new sample rate");
			
			XThrowIfError(AudioOutputUnitStart(THIS->rioUnit), "couldn't start unit");
			
			// we need to rescale the sonogram view's color thresholds for different input
			CFStringRef newRoute;
			size = sizeof(CFStringRef);
			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &newRoute), "couldn't get new audio route");
			if (newRoute) {	
				CFShow(newRoute);
			}
		} catch (CAXException e) {
			char buf[256];
			fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		}
		
	}
}


#pragma mark -RIO Render Callback

static void performUpperCallback(HiJackMgr *mgrPtr, UInt8 byte)
{
    NSAutoreleasePool	 *autoreleasepool = [[NSAutoreleasePool alloc] init];
    if([mgrPtr->theDelegate respondsToSelector:@selector(receive:)]) {
        [mgrPtr->theDelegate receive:byte];
    }
    [autoreleasepool release];
}


static bool isValidLength(UInt32 val)
{
    return ( SHORT < val) && (val < LONG);
}


static bool isTooShort(UInt32 val)
{
    return val < SHORT;
}


static void doUartDecode(HiJackMgr *mgrPtr, UInt32 inNumberFrames, AudioBuffer *inBuff)
{
    static UInt32 phase = 0;
    static Boolean sample = 0;
    
    static UInt32 lastPhase = 0;
    static UInt32 lastSample = 0;
    
    static int decState = STARTBIT;
	static int bitNum = 0;
    
	static uint8_t uartByte = 0;
    static UInt8 parityRx = 0;

	for(int j = 0; j < inNumberFrames; j++) {
    
		float val = *(((SInt32*) inBuff->mData) + j);
        SInt32 diff = phase - lastPhase;
        
		phase += 1;
        sample = !(val < THRESHOLD);
        
		if (sample == lastSample) {
            continue;
        }
        
        Boolean resetState = true;
        
        switch (decState) {
            case STARTBIT:
                if (lastSample == 0 && sample == 1) {
                    // low->high transition. Now wait for a long period
                    decState = STARTBIT_FALL;
                    resetState = false;
                }
                break;
            case STARTBIT_FALL:
                if (isValidLength(diff)) {
                    // looks like we got a 1->0 transition,
                    // start actually decoding the signal.
                    bitNum = 0;
                    parityRx = 0;
                    uartByte = 0;
                    
                    decState = DECODE;
                    resetState = false;
                }
                break;
            case DECODE:
                if (isValidLength(diff)) {
                    // we got a valid sample.
                    if (bitNum < 8) {
                        uartByte = ((uartByte >> 1) + (sample << 7));
                        bitNum += 1;
                        parityRx += sample;
                        resetState = false;
                    }
                    else if(sample == (parityRx & 0x01)) {
                        printf("calll: %X\n", uartByte);
                        performUpperCallback(mgrPtr, uartByte);
                    }
                }
                else if (isTooShort(diff)){
                    // don't update the phase as we have to look for the next transition
                    lastSample = sample;
                    continue;
                }
                break;
            default:
                break;
        }
        lastPhase = phase;
		lastSample = sample;
        
        if (resetState) {
            decState = STARTBIT;
        }
	}
}


static uint8_t getNextBit(uint32_t uartBitTx, uint8_t uartByteTx, uint8_t parity)
{
    uint8_t nextBit;
    
    if (uartBitTx == 0) {
        // start bit
        nextBit = 0;
    }
    else if (uartBitTx == 9) {
        // parity bit
        nextBit = parity & 0x01;
    }
    else if (uartBitTx >= 10) {
        // stop bit
        nextBit = 1;
    }
    else {
        nextBit = (uartByteTx >> (uartBitTx - 1)) & 0x01;
        parity += nextBit;
    }
    
    return nextBit;
}


static float getSign(uint8_t currentBit, uint8_t nextBit)
{
    if (
        (nextBit == currentBit && nextBit == 0) ||
        (nextBit != currentBit && nextBit == 1)
    ) {
        return -1.0;
    }
    else {
        return 1.0;
    }
}


static float getFreq(uint8_t currentBit, uint8_t nextBit)
{
    if (nextBit == currentBit) {
        return HIGHFREQ;
    } else {
        return LOWFREQ;
    }
}


static void doUartEncode(HiJackMgr *mgrPtr, UInt32 inNumberFrames, AudioBuffer *outBuff)
{

    SInt32 values[inNumberFrames];
    
	// UART encode
	static uint32_t period = SAMPLESPERBIT;
    
	static uint8_t uartByteTx = 0x0;
	static uint32_t uartBitTx = 0;
    
	static float uartBitEnc[SAMPLESPERBIT];
	static uint8_t currentBit = 1;
	static uint8_t parityTx = 0;
    
    for(int j = 0; j< inNumberFrames; j++) {
        if (period == SAMPLESPERBIT) {
            period = 0;
        
            // We're at a boundray right now, either advance
            // to the next bit, or start a new byte transmission.
            if (uartBitTx >= NUMSTOPBITS && mgrPtr->newByte == TRUE) {
                mgrPtr->newByte = FALSE;
                
                uartByteTx = mgrPtr->uartByteTransmit;
                uartBitTx = 0;
                parityTx = 0;                
            }
            
            uint8_t nextBit = getNextBit(uartBitTx, uartByteTx, parityTx);
            
            float sign = getSign(currentBit, nextBit);
            float freq = getFreq(currentBit, nextBit);

            for (uint8_t p = 0; p<SAMPLESPERBIT; p++) {
                uartBitEnc[p] = sign * sin(M_PI * 2.0f / mgrPtr->hwSampleRate * freq * (p+1)) * AMPLITUDE;
            }
            
            currentBit = nextBit;
            uartBitTx++;
        }

        values[j] = (SInt32)(uartBitEnc[period++]);
    }
    
    memcpy(outBuff->mData, values, outBuff->mDataByteSize);
}


static void doUartPowerGeneration(UInt32 inNumberFrames, AudioBuffer *outBuff)
{
    static UInt32 phase = 0;
    SInt32 values[inNumberFrames];
    for(int i = 0; i < inNumberFrames; i++) {
        values[i] = (SInt32) (sin(M_PI * phase + 0.5) * AMPLITUDE);
        phase++;
    }
    // copy sine wave into left channels.
    memcpy(outBuff->mData, values, outBuff->mDataByteSize);
}


static OSStatus	PerformThru(
    void *inRefCon, 
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData)
{
	HiJackMgr *THIS = (HiJackMgr *)inRefCon;
    
	OSStatus err = AudioUnitRender(
        THIS->rioUnit,
        ioActionFlags,
        inTimeStamp,
        1,
        inNumberFrames,
        ioData
    );
    
	if (err) {
        printf("PerformThru: error %d\n", (int)err);
        return err;
    }

	doUartDecode(THIS, inNumberFrames, &ioData->mBuffers[0]);
	
	if (THIS->mute == NO) {
		doUartPowerGeneration(inNumberFrames, &ioData->mBuffers[1]);
        doUartEncode(THIS, inNumberFrames, &ioData->mBuffers[0]);
	}
    
	return err;
}


- (void) setDelegate:(id <HiJackDelegate>) delegate {
	theDelegate = delegate;
}


- (id) init {
	newByte = FALSE;
    [self initAudio];
	return self;
}


- (void) initAudio {

	inputProc.inputProc = PerformThru;
	inputProc.inputProcRefCon = self;
    
	try {	
		// Initialize and configure the audio session
		XThrowIfError(
            AudioSessionInitialize(
                NULL,
                NULL,
                rioInterruptionListener,
                self
            ),
            "couldn't initialize audio session"
        );
        
		XThrowIfError(
            AudioSessionSetActive(true),
            "couldn't set audio session active\n"
        );
		
		UInt32 audioCategory = kAudioSessionCategory_PlayAndRecord;
		XThrowIfError(
            AudioSessionSetProperty(
                kAudioSessionProperty_AudioCategory,
                sizeof(audioCategory),
                &audioCategory
            ),
            "couldn't set audio category"
        );
        
		XThrowIfError(
            AudioSessionAddPropertyListener(
                kAudioSessionProperty_AudioRouteChange,
                propListener,
                self
            ),
            "couldn't set property listener"
        );
		
		Float32 preferredBufferSize = .005;
		XThrowIfError(
            AudioSessionSetProperty(
                kAudioSessionProperty_PreferredHardwareIOBufferDuration,
                sizeof(preferredBufferSize),
                &preferredBufferSize
            ),
            "couldn't set i/o buffer duration"
        );
		
		UInt32 size = sizeof(hwSampleRate);
		XThrowIfError(
            AudioSessionGetProperty(
                kAudioSessionProperty_CurrentHardwareSampleRate,
                &size,
                &hwSampleRate
            ),
            "couldn't get hw sample rate"
        );
		
		XThrowIfError(
            SetupRemoteIO(rioUnit, inputProc, thruFormat),
            "couldn't setup remote i/o unit"
        );
		
		dcFilter = new DCRejectionFilter[thruFormat.NumberChannels()];
		
		UInt32 maxFPSt;
		size = sizeof(maxFPSt);
        
		XThrowIfError(
            AudioUnitGetProperty(
                rioUnit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &maxFPSt,
                &size
            ),
            "couldn't get the remote I/O unit's max frames per slice"
        );
        
		self.maxFPS = maxFPSt;
		
		XThrowIfError(
            AudioOutputUnitStart(rioUnit),
            "couldn't start remote i/o unit"
        );
		
		size = sizeof(thruFormat);
		XThrowIfError(
            AudioUnitGetProperty(
                rioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &thruFormat,
                &size),
            "couldn't get the remote I/O unit's output client format"
        );
		
		unitIsRunning = 1;
	}
	catch (CAXException &e) {
		char buf[256];
		fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		unitIsRunning = 0;
		if (dcFilter) delete[] dcFilter;
	}
	catch (...) {
		fprintf(stderr, "An unknown error occurred\n");
		unitIsRunning = 0;
		if (dcFilter) delete[] dcFilter;
	}
}

- (int) send:(UInt8) data {
	if (newByte == FALSE) {
		// transmitter ready
		self.uartByteTransmit = data;
		newByte = TRUE;
		return 0;
	} else {
		return 1;
	}
}


- (void)dealloc
{
	delete[] dcFilter;
	[super dealloc];

}

@end
