//
//  ViewController.m
//  Smokalyzer
//
//  Created by Andrew Robinson on 10/29/12.
//  Copyright (c) 2012 Andrew Robinson. All rights reserved.
//

#import "ViewController.h"
#include <pthread.h>

@interface ViewController ()

@end

@implementation ViewController
{
    uint16_t currentVal;
    uint16_t maxVal;
    
    uint16_t lowCalVal;
    uint16_t highCalVal;

    uint16_t newLowCalVal;
    uint16_t newHighCalVal;
    
    pthread_mutex_t mutex;
    
    enum uartRxEnum {
        uartRx_data,
        uartRx_dataEscape,
        uartRx_size,
        uartRx_start
    };
    
    // Input buffer, big enough to store escaped
    // characters and stuff.
    uint8_t uartRxBuff[20];
    uint8_t uartRxPosition;
    uint8_t uartRxReceiveSize;
    enum uartRxEnum uartRxState;
    
    uint16_t storedValues[16];
    uint8_t storedValueIdx;
    
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    hiJackMgr = [[HiJackMgr alloc] init];
    
    [hiJackMgr setDelegate:self];

    
    currentVal = 0;
    lowCalVal = 0;
    highCalVal = 1;
    
    uartRxPosition = 0;
    uartRxReceiveSize = 0;
    uartRxState = uartRx_start;
    
    storedValueIdx = 0;
    
    pthread_mutex_init(&mutex, NULL);
    
    [self updateLabels];
	// Do any additional setup after loading the view, typically from a nib.
}

- (int) receive:(UInt8)val
{
    if (uartRxPosition > 18) {
        uartRxPosition = 0;
        uartRxState = uartRx_start;
    }
    
    if (val == 0xDD &&
        uartRxState != uartRx_dataEscape) {
        uartRxState = uartRx_size;
        uartRxPosition = 0;
        return 0;
    }
    
    switch (uartRxState) {
        case uartRx_data:
            if (val == 0xCC) {
                uartRxState = uartRx_dataEscape;
                uartRxReceiveSize--;
                break;
            }
            // INTENTIONAL FALL THROUGH
        case uartRx_dataEscape:
            uartRxBuff[uartRxPosition++] = val;
            if (uartRxPosition == uartRxReceiveSize) {
                
                // Update the current CO, and cal values.
                uint8_t i = 0;
                uint8_t sum = 0;
                
                for (i = 0; i < uartRxPosition - 1; i++) {
                    sum += uartRxBuff[i];
                }
                
                if (sum == uartRxBuff[uartRxPosition - 1]) {
                    
                    pthread_mutex_lock(&mutex);
                    storedValues[storedValueIdx++ % 16] = (uartRxBuff[0] << 8) + uartRxBuff[1];
                    
                    uint32_t sum = 0;
                    for (i = 0; i < 16; i++)
                    {
                        sum += storedValues[i];
                    }
                    currentVal = sum >> 4;
                    lowCalVal = (uartRxBuff[2] << 8) + uartRxBuff[3];
                    highCalVal = (uartRxBuff[4] << 8) + uartRxBuff[5];
                    pthread_mutex_unlock(&mutex);
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self updateLabels];
                });
                
                uartRxState = uartRx_start;
            }
            break;
        case uartRx_size:
            // Arbitrary large packet size
            if (val > 18) {
                uartRxState = uartRx_start;
                break;
            }
            uartRxReceiveSize = val;
            uartRxState = uartRx_data;
            break;
        default:
            break;
    }
    return 0;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)dealloc {
    printf("WHARADADSFD");
    //[_currentLabel release];
    //[_maxLabel release];
    //[super dealloc];
}

- (void)viewDidUnload {
    [self setCurrentLabel:nil];
    [self setMaxLabel:nil];
    [super viewDidUnload];
}

- (IBAction)resetMax:(id)sender {
    pthread_mutex_lock(&mutex);
    maxVal = lowCalVal;
    pthread_mutex_unlock(&mutex);
}

- (IBAction)calibrateZeroBtn:(id)sender {
    pthread_mutex_lock(&mutex);
    newLowCalVal = currentVal;
    newHighCalVal = highCalVal;
    pthread_mutex_unlock(&mutex);
    
    [self doUpdate];
}

- (IBAction)calibrateSpanBtn:(id)sender {
    pthread_mutex_lock(&mutex);
    newHighCalVal = currentVal;
    newLowCalVal = lowCalVal;
    pthread_mutex_unlock(&mutex);
    
    [self doUpdate];
}

- (void)doUpdate {
    
    pthread_mutex_lock(&mutex);
    uint8_t outBuffer[] = {
        (newLowCalVal >> 8) & 0xFF,
        (newLowCalVal & 0xFF),
        (newHighCalVal >> 8) & 0xFF,
        (newHighCalVal & 0xFF)
    };
    pthread_mutex_unlock(&mutex);
    
    uint8_t checksum = 0;
    uint8_t outgoingByteArray[32];
    outgoingByteArray[0] = 0xDD;
    
    uint8_t outgoingBytePos = 2;
    for (uint8_t i = 0; i < 4; i++) {
        if (outBuffer[i] == 0xDD || outBuffer[i] == 0xCC) {
            outgoingByteArray[outgoingBytePos++] = 0xCC;
            checksum += 0xCC;
        }
        
        outgoingByteArray[outgoingBytePos++] = outBuffer[i];
        checksum += outBuffer[i];
    }
    
    outgoingByteArray[1] = outgoingBytePos - 1;
    outgoingByteArray[outgoingBytePos++] = checksum;
    
    bool hasUpdated = false;
    while(!hasUpdated) {
        pthread_mutex_lock(&mutex);
        hasUpdated = (newHighCalVal == highCalVal) && (newLowCalVal == lowCalVal);
        pthread_mutex_unlock(&mutex);
        
        for (int i = 0; i < outgoingBytePos; i++) {
            [hiJackMgr send:outgoingByteArray[i]];
            [NSThread sleepForTimeInterval:0.1];
        }
    }
}

- (void)updateLabels {
    pthread_mutex_lock(&mutex);
    if (maxVal < currentVal) {
        maxVal = currentVal;
    }
    
    self.currentLabel.text = [NSString stringWithFormat: @"%.2f",
                              ((double)currentVal - (double)lowCalVal) / (double)(highCalVal - lowCalVal) * 20];
    self.maxLabel.text = [NSString stringWithFormat: @"%.2f",
                          ((double)maxVal - (double)lowCalVal) / (double)(highCalVal - lowCalVal) * 20];
    
    pthread_mutex_unlock(&mutex);
}

@end
