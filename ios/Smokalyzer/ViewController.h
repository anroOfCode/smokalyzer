//
//  ViewController.h
//  Smokalyzer
//
//  Created by Andrew Robinson on 10/29/12.
//  Copyright (c) 2012 Andrew Robinson. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "HiJackMgr.h"


@interface ViewController : UIViewController <HiJackDelegate> {
    HiJackMgr * hiJackMgr;
    
}
- (IBAction)resetMax:(id)sender;
- (IBAction)calibrateZeroBtn:(id)sender;
- (IBAction)calibrateSpanBtn:(id)sender;

- (void)updateLabels;
- (void)doUpdate;

@property (retain, nonatomic) IBOutlet UILabel *currentLabel;
@property (retain, nonatomic) IBOutlet UILabel *maxLabel;

@end
