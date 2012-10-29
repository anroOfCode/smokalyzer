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
 * Original Version: Thomas Schmid, Dec 23th, 2010
 * Significant Revisions: Andrew Robinson, October 24th, 2012
 */

module HiJackAppM {
    uses {
      interface Boot;
      interface Leds;
      interface HplMsp430GeneralIO as ADCIn;
      interface Timer<TMilli> as ADCTimer;
      interface Timer<TMilli> as HijackTimer;
      interface HiJack;
    }
}

implementation {
    uint8_t uartByteTx[6] = {0, 0, 0, 0, 0, 0};
    uint8_t uartByteRx;

    uint8_t uartByteTxBuff[16] = {0xDD, 0x07, 0xAA, 0xBB, 0x00, 0x00, 0x00, 0x00, 0xAE};
    
    // Sending position for uartByteTxBuff.
    uint8_t uartByteTxBuffPos = 0;

    uint16_t adcBuffer;
    uint8_t adcCounter = 0;

    void updateTxBuffer() {
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
            if (uartByteTx[byteTxIdx] == 0xDD) {
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

    void task sendTask()
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

            //call HiJack.send(uartByteTxBuff[uartByteTxBuffPos++]);      
        }
    }

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

            // Initialize a 15ms periodic timer
            // to read and send the data.
            call ADCTimer.startPeriodic(15);
            call HijackTimer.startPeriodic(20);
        }
    }

    // Periodic timer task to cause a sampling of the ADC
    // every 15ms or so.
    event void ADCTimer.fired()
    {
        atomic {
            post sendTask();
        }
    }

    event void HijackTimer.fired()
    {
        atomic {
            if (uartByteTxBuffPos == 9) {
                updateTxBuffer();
                uartByteTxBuffPos = 0;
            }
            call HiJack.send(uartByteTxBuff[uartByteTxBuffPos++]);           
        }
    }

    async event void HiJack.sendDone(uint8_t byte, error_t error)
    {
    }

    async event void HiJack.receive(uint8_t byte) 
    {
        atomic {
            // map the byte to sampling rate
            //samplePeriod = (uint16_t)2560.0/(byte+1)/2;
            uartByteRx = byte;
            //call ADCTimer.stop();
            //call ADCTimer.startOneShot(samplePeriod);
        }
    }
}

