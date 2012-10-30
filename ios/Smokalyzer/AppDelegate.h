//
//  AppDelegate.h
//  Smokalyzer
//
//  Created by Andrew Robinson on 10/29/12.
//  Copyright (c) 2012 Andrew Robinson. All rights reserved.
//

#import <UIKit/UIKit.h>

@class HiJackMgr;

@interface AppDelegate : UIResponder <UIApplicationDelegate> {
    HiJackMgr * hiJackMgr;
}

@property (strong, nonatomic) UIWindow *window;

@end
