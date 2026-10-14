// Tweak.x —— Logos 写法（Theos）
// 作用：运行时伪造 CloudKit entitlements + 本地容器重定向，使个人 Apple ID 签装的
//       com.lxm.ysbrowser 不在启动期 CloudKit 校验(CKSDKVersion)时秒退。
//
// 思路分三层，层层兜底（任何一层生效都能救活启动）：
//   A. 伪造权限：hook 私有类 CKEntitlements 的 initWithEntitlementsDict:，把缺的 CloudKit 键补上；
//      并 hook 其“读取当前进程权限”的类方法，直接返回伪字典。
//   B. 容器重定向：NSUbiquitousKeyValueStore / NSUserDefaults(suite) / App Group 指向本地可写目录。
//   C. 兜底禁用：若 A 在你这个 SDK27 上 selector 对不上（CloudKit 私有实现随版本变），
//      直接让 YSKit 的 iCloud 启动入口空返回（见文件末尾 %hookf + MSHookFunction 示例）。
//
// 依赖：Theos + CydiaSubstrate（用户态，不越狱）。编译见 Makefile / README_INJECT.md。

#import <substrate.h>
#import "ysfakeck.h"
#import <objc/runtime.h>
#import <dlfcn.h>

// ———————————————————————————————————————————————
// A. 伪造 CloudKit entitlements
// ———————————————————————————————————————————————
// CKEntitlements 是 CloudKit 私有类；它承载“本进程拥有哪些 iCloud 权限”。
// 不同 SDK 其初始化入口略有差异，这里 hook 最常见的 initWithEntitlementsDict:。
%hook CKEntitlements
- (id)initWithEntitlementsDict:(NSDictionary *)dict {
    NSDictionary *merged = YSMergeFake(dict);
    YSLog(@"CKEntitlements initWithEntitlementsDict: 注入伪权限, keys=%@", merged.allKeys);
    return %orig(merged);
}
%end

// ———————————————————————————————————————————————
// B. 容器重定向（NSUbiquitousKeyValueStore / NSUserDefaults suite）
// ———————————————————————————————————————————————
%hook NSUserDefaults
// 宿主用 suiteName 读写 iCloud/app-group 配置；个人证书下该 suite 可能不可用 → 重定向到本地。
- (id)initWithSuiteName:(NSString *)suiteName {
    if (suiteName && ([suiteName hasPrefix:@"group."] || [suiteName containsString:@"iCloud"])) {
        YSLog(@"NSUserDefaults suite '%@' -> 本地 standardUserDefaults", suiteName);
        return [NSUserDefaults standardUserDefaults];
    }
    return %orig;
}
%end

%hook NSUbiquitousKeyValueStore
// defaultStore 若因缺 kvstore 权限返回 nil 或崩，这里保证给到一个可用实例（本地）。
+ (id)defaultStore {
    id s = %orig;
    if (s) return s;
    YSLog(@"NSUbiquitousKeyValueStore defaultStore 原返回 nil，返回本地占位实例");
    return [[NSUbiquitousKeyValueStore alloc] init];
}
%end

// ———————————————————————————————————————————————
// 构造器：安装那些“类名/方法在编译期拿不到”的 hook（私有类用 MSHookMessageEx 动态装）
// ———————————————————————————————————————————————
%ctor {
    @autoreleasepool {
        // A2. 有的 CloudKit 版本是通过 CKContainer 的内部 setup 读权限，这里再补 hook 两个常见私有入口。
        Class CKC = objc_getClass("CKContainer");
        if (CKC) {
            // -[CKContainer _setupWithContainerID:options:]：允许构造，不让它因权限缺失而 throw。
            SEL sel = sel_registerName("_setupWithContainerID:options:");
            Method m = class_getInstanceMethod(CKC, sel);
            if (m) {
                static IMP (*orig_setup)(id, SEL, id, id);
                IMP rep = imp_implementationWithBlock(^id(id self_, id cid, id opts){
                    @try { return ((id(*)(id,SEL,id,id))orig_setup)(self_, sel, cid, opts); }
                    @catch (NSException *e) { YSLog(@"_setupWithContainerID 吞掉异常 %@", e); return self_; }
                });
                MSHookMessageEx(CKC, sel, rep, (IMP *)&orig_setup);
                YSLog(@"已 hook CKContainer _setupWithContainerID:options:");
            }
        }
        // A3. 兜底：直接伪造“当前进程 entitlements”的读取点（类方法名随 SDK 变，按需改）。
        //      常见候选：+[CKEntitlements entitlementsForCurrentProcess] / +[CKEntitlements currentEntitlements]
        Class CKE = objc_getClass("CKEntitlements");
        const char *cands[] = {"entitlementsForCurrentProcess", "currentEntitlements", "processEntitlements", NULL};
        for (int i = 0; CKE && cands[i]; i++) {
            SEL s = sel_registerName(cands[i]);
            if ([CKE respondsToSelector:s]) {
                static IMP orig_ce;
                IMP rep = imp_implementationWithBlock(^id(id cls){
                    YSLog(@"CKEntitlements +%s 返回伪权限", cands[i]);
                    return YSFakeEntitlements();
                });
                MSHookMessageEx(object_getClass(CKE), s, rep, (IMP *)&orig_ce);
            }
        }

        // 触发一次本地容器创建（便于后续重定向有真实目录）
        YSLog(@"本地容器: %@", YSLocalContainerURL().path);
    }
}

// ———————————————————————————————————————————————
// C. 兜底禁用（若 A 在你的 SDK27 上无效，取消注释启用）
// ———————————————————————————————————————————————
// YSKit 启动期进入 CloudKit 的两个点（本仓分析所得，对应硬补丁 v6 的偏移）：
//   - ObjC 方法 -[? uuidsOfUserDevices_iCloudInit] / _iCloudSync  (可直接 %hook 该类，空返回)
//   - Swift 静态 getRecordData(...)                               (需 MSHookFunction + dlsym 符号)
//
// C1. ObjC 方法（把宿主承载 iCloud 的类名填上，类名见 README“如何定位类名”）：
// %hook YSXXXiCloudManager
// - (id)uuidsOfUserDevices_iCloudInit { return nil; }
// - (void)uuidsOfUserDevices_iCloudSync { return; }
// %end
//
// C2. Swift 符号（SDK27 下不要用偏移，用符号）：
//   在 box/mac 上执行：  nm -arch arm64 YSKit | grep -i getRecordData
//   取到形如  _$s5YSKit...getRecordData...  的 mangled 名，填到下面：
/*
static void *orig_getRecordData;
static id my_getRecordData(void *a,void *b,void *c,void *d,void *e){ return nil; }
__attribute__((constructor)) static void install_fallback_C2(void){
    void *sym = dlsym(RTLD_DEFAULT, "$s5YSKit_REPLACE_WITH_REAL_MANGLED_getRecordData");
    if (sym) { MSHookFunction(sym, (void*)my_getRecordData, &orig_getRecordData);
               YSLog(@"MSHookFunction getRecordData 已装"); }
    else     { YSLog(@"未找到 getRecordData 符号，检查 nm 结果"); }
}
*/
