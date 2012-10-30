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
    
    uint8_t incomingByteArray[32];
    uint8_t incomingBytePosition;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    hiJackMgr = [[HiJackMgr alloc] init];
    [hiJackMgr setDelegate:self];
    
    currentVal = 0;
    lowCalVal = 0;
    highCalVal = 1;
    
    incomingBytePosition = 0;
    
    pthread_mutex_init(&mutex, NULL);
    
    [self updateLabels];
	// Do any additional setup after loading the view, typically from a nib.
}

- (int) receive:(UInt8)data
{
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateLabels];
    });

    return 0;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)dealloc {
    [_currentLabel release];
    [_maxLabel release];
    [super dealloc];
}

- (void)viewDidUnload {
    [self setCurrentLabel:nil];
    [self setMaxLabel:nil];
    [super viewDidUnload];
}

- (IBAction)resetMax:(id)sender {
    maxVal = lowCalVal;
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
    uint8_t outBuffer[] = {
        (lowCalVal << 8) & 0xFF,
        (lowCalVal & 0xFF),
        (highCalVal << 8) & 0xFF,
        (highCalVal & 0xFF)
    };
    
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
                              ((double)currentVal - (double)lowCalVal) / (double)(highCalVal - lowCalVal)];
    self.maxLabel.text = [NSString stringWithFormat: @"%.2f",
                          ((double)currentVal - (double)lowCalVal) / (double)(highCalVal - lowCalVal)];
    pthread_mutex_unlock(&mutex);
}

@end
