//
//  GBLaunchAtLogin.m
//  GBLaunchAtLogin
//
//  Created by Luka Mirosevic on 04/03/2013.
//  Copyright (c) 2013 Goonbee. All rights reserved.
//
//  Updated to use SMAppService (macOS 13+) replacing deprecated LSSharedFileList APIs.

#import "GBLaunchAtLogin.h"
#import <ServiceManagement/ServiceManagement.h>

@implementation GBLaunchAtLogin

+(BOOL)isLoginItem {
    return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
}

+(void)addAppAsLoginItem {
    [[SMAppService mainAppService] registerAndReturnError:nil];
}

+(void)removeAppFromLoginItems {
    [[SMAppService mainAppService] unregisterAndReturnError:nil];
}

@end
