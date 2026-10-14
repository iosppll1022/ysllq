// inject_cloudkit.m —— 纯 ObjC + <substrate.h> 写法（不依赖 Logos 预处理器）
// 可用 Theos(可直接编 .m)，也可用裸 clang（见 README_INJECT.md 的 clang 命令）。
// 功能同 Tweak.x：运行时伪造 CloudKit entitlements + 容器重定向，救活个人 Apple ID 启动。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <substrate.h>
#import "ysfakeck.h"

// ========== A. CKEntitlements initWithEntitlementsDict: ==========
static id (*orig_CKE_init)(id, SEL, id);
static id my_CKE_init(id self_, SEL _cmd, NSDictionary *dict) {
    NSDictionary *merged = YSMergeFake(dict);
    YSLog(@"CKEntitlements initWithEntitlementsDict: 注入伪权限 keys=%@", merged.allKeys);
    return orig_CKE_init(self_, _cmd, merged);
}

// ========== A2. CKContainer _setupWithContainerID:options: （吞异常，允许构造）==========
static id (*orig_CKC_setup)(id, SEL, id, id);
static id my_CKC_setup(id self_, SEL _cmd, id cid, id opts) {
    @try { return orig_CKC_setup(self_, _cmd, cid, opts); }
    @catch (NSException *e) { YSLog(@"_setupWithContainerID 吞异常 %@", e); return self_; }
}

// ========== A3. +[CKEntitlements entitlementsForCurrentProcess] 之类，直接返回伪字典 ==========
static id (*orig_CKE_current)(id, SEL);
static id my_CKE_current(id cls, SEL _cmd) {
    YSLog(@"CKEntitlements 读取当前进程权限 -> 返回伪字典");
    return YSFakeEntitlements();
}

// ========== B. NSUserDefaults suite 重定向 ==========
static id (*orig_NSUD_suite)(id, SEL, NSString *);
static id my_NSUD_suite(id self_, SEL _cmd, NSString *suite) {
    if (suite && ([suite hasPrefix:@"group."] || [suite containsString:@"iCloud"])) {
        YSLog(@"NSUserDefaults suite '%@' -> standardUserDefaults", suite);
        return [NSUserDefaults standardUserDefaults];
    }
    return orig_NSUD_suite(self_, _cmd, suite);
}

// ========== B2. NSUbiquitousKeyValueStore defaultStore 保底 ==========
static id (*orig_UKV_default)(id, SEL);
static id my_UKV_default(id cls, SEL _cmd) {
    id s = orig_UKV_default(cls, _cmd);
    if (s) return s;
    YSLog(@"NSUbiquitousKeyValueStore defaultStore nil -> 本地占位");
    return [[objc_getClass("NSUbiquitousKeyValueStore") alloc] init];
}

// 工具：安全 hook 实例方法
static void hookInstance(Class c, const char *selName, IMP rep, void *origSlot) {
    if (!c) return;
    SEL s = sel_registerName(selName);
    if (!class_getInstanceMethod(c, s)) return;
    MSHookMessageEx(c, s, rep, (IMP *)origSlot);
    YSLog(@"hooked -[%s %s]", class_getName(c), selName);
}
// 工具：安全 hook 类方法（hook 元类）
static void hookClassMethod(Class c, const char *selName, IMP rep, void *origSlot) {
    if (!c) return;
    SEL s = sel_registerName(selName);
    if (!class_getClassMethod(c, s)) return;
    MSHookMessageEx(object_getClass(c), s, rep, (IMP *)origSlot);
    YSLog(@"hooked +[%s %s]", class_getName(c), selName);
}

// ========== 构造器：进程加载即安装全部 hook ==========
__attribute__((constructor))
static void ysfakeck_init(void) {
    @autoreleasepool {
        YSLog(@"inject_cloudkit 构造器启动");

        Class CKE = objc_getClass("CKEntitlements");
        hookInstance(CKE, "initWithEntitlementsDict:", (IMP)my_CKE_init, &orig_CKE_init);
        const char *cur[] = {"entitlementsForCurrentProcess","currentEntitlements","processEntitlements",NULL};
        for (int i=0; CKE && cur[i]; i++)
            hookClassMethod(CKE, cur[i], (IMP)my_CKE_current, &orig_CKE_current);

        Class CKC = objc_getClass("CKContainer");
        hookInstance(CKC, "_setupWithContainerID:options:", (IMP)my_CKC_setup, &orig_CKC_setup);

        hookInstance(objc_getClass("NSUserDefaults"), "initWithSuiteName:", (IMP)my_NSUD_suite, &orig_NSUD_suite);
        hookClassMethod(objc_getClass("NSUbiquitousKeyValueStore"), "defaultStore", (IMP)my_UKV_default, &orig_UKV_default);

        YSLog(@"本地容器: %@", YSLocalContainerURL().path);

        // ===== C. 兜底：若上面在你的 SDK27 上仍救不活，启用下面任一 =====
        // C1. ObjC：禁用 YSKit iCloud 启动方法（把真实类名填上，见 README“如何定位类名”）
        // hookInstance(objc_getClass("YSXXXiCloudManager"), "uuidsOfUserDevices_iCloudInit",
        //              (IMP)^(id s, SEL c){ return (id)nil; }, &someOrigSlot);
        //
        // C2. Swift getRecordData：用符号名（勿用偏移），mangled 名由 `nm -arch arm64 YSKit | grep getRecordData` 取。
        // void *sym = dlsym(RTLD_DEFAULT, "$s5YSKit_REPLACE_getRecordData_MANGLED");
        // if (sym) { static void *o; MSHookFunction(sym, (void*)(+[](){ }), &o); }
    }
}
