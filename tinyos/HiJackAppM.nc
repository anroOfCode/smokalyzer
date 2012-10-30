/**
 * Copyright (c) 2010 The Regents of the University of Michigan. All
 * rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 
 * - Redistributions of source code must retain the above copyright
 *  notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *  notice, this list of conditions and the following disclaimer in the
 *  documentation and/or other materials provided with the
 *  distribution.
 * - Neither the name of the copyright holder nor the names of
 *  its contributors may be used to endorse or promote products derived
 *  from this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Author: Andrew Robinson, October 24th, 2012
 */

module HiJackAppM {
    uses {
      interface Boot;
      interface Leds;
      interface HplMsp430GeneralIO as ADCIn;
      interface Timer<TMilli> as ADCTimer;
      interface Timer<TMilli> as HijackTimer;
      interface HiJack;
      interface InternalFlash;
    }
}

implementation {
    ///////////////////////////////////
    // Primary interrupt-driven tasks:
    ///////////////////////////////////

    // Reads the ADC and fills the in-memory tx buffer
    // with the ADC values.
    void task readAdcTask();

    // Sends the tx send buffer to the phone host
    // and generates it at packet boundaries.
    void task sendDataTask();

    /////////////////////////////////
    // Helper functions:
    /////////////////////////////////

    // Takes uartByteTx and generates a new uartByteTxBuff
    // from it, call at packet boundraies.
    void updateTxBuffer();

    // Recieves a single byte and controls receiving
    // packets. Since we're using a really simple
    // implementation this function is fairly rudimentary.
    void updateRxBuffer(uint8_t byte);

    // Checks the RX buffer. If the checksum looks good
    // it will write the new calibration data to memory.
    void processRxBuffer();

    //////////////////////////////////
    // Member variables
    //////////////////////////////////

    // Data buffer, the ADC and other values write
    // to this thing.
    // Bytes 0-1 : 16-bit Current ADC Reading
    // Bytes 2-3 : 16-bit Low Calibration Point
    // Bytes 4-5 : 16-bit High Calibration Point
    uint8_t uartByteTx[6] = {0, 0, 0, 0, 0, 0};

    // Output buffer, bigger to allow for the header byte,
    // length, and escaping of special characters.
    uint8_t uartByteTxBuff[16] = {0xDD, 0x07, 0xAA, 0xBB, 0x00, 0x00, 0x00, 0x00, 0xAE};

    enum uartRxEnum {
        uartRx_data,
        uartRx_dataEscape,
        uartRx_size,
        uartRx_start
    };
    // Input buffer, big enough to store escaped
    // characters and stuff.
    uint8_t uartRxBuff[11];
    uint8_t uartRxPosition = 0;
    uint8_t uartRxReceiveSize = 0;
    enum uartRxEnum uartRxState = uartRx_start;

    // Sending position for uartByteTxBuff.
    uint8_t uartByteTxBuffPos = 0;

    // 16 12-bit ADC readings are added to this
    // buffer to obtain a 16-bit sample with gaussian
    // over-sampling.
    uint16_t adcBuffer;

    uint8_t adcCounter = 0;

    ////////////////////////////////
    // Implementation
    ////////////////////////////////

    ////////////////////////////////
    // Wired up events

    event void Boot.booted()
    {
        // Enables ADC functionality on
        // this pin. 
        call ADCIn.makeInput();
        call ADCIn.selectModuleFunc();

        atomic {

            // Turn on ADC12, set sampling time
            ADC12CTL0 = ADC12ON + SHT0_7;
            ADC12CTL1 = CSTARTADD_0 + SHP;

            // select A6, Vref=AVcc
            ADC12MCTL0 = INCH_6;

            // Build a blank tx buffer
            updateTxBuffer();

            // Read calibration data from
            // MSP430 flash.
            call InternalFlash.read((void*)0x00, uartByteTx + 2, 4);

            // Start a 15ms periodic timer
            // to read the ADC pin
            call ADCTimer.startPeriodic(15);

            // Start a 15ms periodic timer to
            // send the data. 
            call HijackTimer.startPeriodic(15);
        }
    }


    async event void HiJack.sendDone(uint8_t byte, error_t error)
    {
    }

    async event void HiJack.receive(uint8_t byte) 
    {
        atomic {
            updateRxBuffer(byte);
        }
    }

    // Periodic timer task to cause a sampling of the ADC
    // every 15ms or so.
    event void ADCTimer.fired()
    {
        atomic {
            post readAdcTask();
        }
    }

    event void HijackTimer.fired()
    {
        atomic {
            post sendDataTask();
        }
    }

    ////////////////////////////////
    // Tasks

    void task readAdcTask()
    {
        // enable ADC conversion
        ADC12CTL0 |= ENC + ADC12SC;

        // TODO: Wait for conversion to complete. This is
        // not the best way to do things, but getting
        // the 12-bit ADC TinyOS library working will
        // take longer.
        while (ADC12CTL1 & ADC12BUSY);

        adcBuffer += ADC12MEM0;
        adcCounter++;

        atomic {
            // By sampling 16 times we get a few bits of
            // extra data.
            if (adcCounter == 16) {
                uartByteTx[0] = (adcBuffer >> 8) & 0xFF;
                uartByteTx[1] = adcBuffer & 0xFF;
                adcCounter = 0;
                adcBuffer = 0;
            }
        }
    }

    void task sendDataTask()
    {
        atomic {
            if (uartByteTxBuffPos == 9) {
                updateTxBuffer();
                uartByteTxBuffPos = 0;
            }
            call HiJack.send(uartByteTxBuff[uartByteTxBuffPos++]);
        }
    }

    ////////////////////////////////
    // Helper Functions

    void updateTxBuffer()
    {
        uint8_t byteTxIdx = 0;
        uint8_t buffTxIdx = 0;
        uint8_t checksum = 0;

        // Start byte
        uartByteTxBuff[buffTxIdx++] = 0xDD;

        // Set length to zero for now.
        uartByteTxBuff[buffTxIdx++] = 0;

        for (byteTxIdx = 0; byteTxIdx < 6; byteTxIdx++) {
            // Escape the byte if it looks like our
            // beloved start byte.
            if (uartByteTx[byteTxIdx] == 0xDD ||
                uartByteTx[byteTxIdx] == 0xCC) {
                uartByteTxBuff[buffTxIdx++] = 0xCC;
                checksum += 0xCC;
            }

            uartByteTxBuff[buffTxIdx++] = uartByteTx[byteTxIdx];
            checksum += uartByteTx[byteTxIdx];
        }

        // Set the length equal to the data + checksum
        // length.
        uartByteTxBuff[1] = buffTxIdx - 1;

        uartByteTxBuff[buffTxIdx++] = checksum;

        // Escape the buffer just in case, we should
        // rely on the length however to send.
        uartByteTxBuff[buffTxIdx++] = 0;
    }

    void updateRxBuffer(uint8_t val) 
    {
        if (val == 0xDD &&
            uartRxState != uartRx_dataEscape) {
            uartRxState = uartRx_size;
            uartRxPosition = 0;
            return;
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
                    processRxBuffer();
                    uartRxState = uartRx_start;
                }
                break;
            case uartRx_size:
                // Arbitrary large packet size
                if (val > 20) {
                    uartRxState = uartRx_start;
                    break;
                }
                uartRxReceiveSize = val;
                uartRxState = uartRx_data;
                break;
            default:
                break;
        }
    }

    void processRxBuffer() 
    {
        uint8_t i = 0;
        uint8_t sum = 0;

        for (i = 0; i < uartRxPosition - 1; i++) {
            sum += uartRxBuff[i];
        }

        if (sum == uartRxBuff[uartRxPosition - 1]) {
            P4DIR |= (1 << 5);
            P4OUT |= (1 << 5);
            call InternalFlash.write((void*)0x00, uartRxBuff, 4);
        }
    }
}