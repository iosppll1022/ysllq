// ysfakeck.h —— 公共辅助：构造伪造的 CloudKit entitlements 字典 + 本地容器发现
// 目标 App：com.lxm.ysbrowser（25.5/2，iOS15 / SDK27，Foundation 5027，CloudKit 2710）
// 说明：个人免费 Apple ID 证书签名后，二进制里本就没有 CloudKit/iCloud/app-groups 权限，
//       CloudKit 在启动期做 entitlement 校验时拿不到这些键 → 抛未捕获异常（栈顶 CKSDKVersion）→ 秒退。
//       本头文件集中提供“伪造的权限字典”和“可写本地容器目录”，供 .x / .m 两种 hook 实现调用。

#import <Foundation/Foundation.h>

// —— 这些常量按目标 App 改；默认取自 com.lxm.ysbrowser —— //
static NSString * const kYSTeamContainerID   = @"iCloud.com.lxm.ysbrowser";
static NSString * const kYSAppGroupID         = @"group.ysbrowser";

// 构造一份“看起来齐全”的 entitlements 字典（CloudKit 校验要的键都给上）
static inline NSDictionary *YSFakeEntitlements(void) {
    return @{
        @"com.apple.developer.icloud-services"               : @[ @"CloudKit", @"CloudDocuments" ],
        @"com.apple.developer.icloud-container-environment"  : @"Production",
        @"com.apple.developer.icloud-container-identifiers"  : @[ kYSTeamContainerID ],
        @"com.apple.developer.ubiquity-container-identifiers": @[ kYSTeamContainerID ],
        @"com.apple.developer.icloud-container-development-container-identifiers": @[ kYSTeamContainerID ],
        @"com.apple.security.application-groups"             : @[ kYSAppGroupID ],
        // 有些校验会读 team-id / application-identifier；给个占位即可（重签后真实值由描述文件决定）
        @"com.apple.developer.ubiquity-kvstore-identifier"   : kYSTeamContainerID,
    };
}

// 把“宿主真实（重签后）entitlements”与伪字典合并：真实有的保留，缺的用伪造补齐。
static inline NSDictionary *YSMergeFake(NSDictionary *real) {
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:(real ?: @{})];
    [YSFakeEntitlements() enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop){
        if (!m[k]) m[k] = v;     // 只补缺，不覆盖宿主真实已有的
    }];
    return m;
}

// 发现/创建一个“确实存在、可写”的本地容器目录，用来顶替 iCloud/ubiquity 容器。
// 优先用重签后真实存在的 App Group 容器；没有就退回 App 沙盒 Library/YSFakeCloud。
static inline NSURL *YSLocalContainerURL(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *url = [fm containerURLForSecurityApplicationGroupIdentifier:kYSAppGroupID];
    if (!url) {
        NSURL *lib = [[fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] firstObject];
        url = [lib URLByAppendingPathComponent:@"YSFakeCloud" isDirectory:YES];
    }
    [fm createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:NULL];
    return url;
}

// 统一日志前缀，便于你在 Console.app 过滤
#define YSLog(fmt, ...) NSLog(@"[ysfakeck] " fmt, ##__VA_ARGS__)
