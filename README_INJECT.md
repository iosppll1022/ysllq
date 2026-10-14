# ysfakeck —— 运行时伪造 CloudKit 权限的注入 dylib（源码 + 编译/注入说明）

目标 App：**com.lxm.ysbrowser 25.5/2**（iOS15 / SDK27，Foundation 5027，CloudKit 2710）
目的：用个人免费 Apple ID（无 CloudKit/iCloud/app-groups 权限）签装时，**不在启动期 CloudKit
`CKSDKVersion` 权限校验处秒退**；Pro 功能保持可用（Pro 另由你现有 nuclear/硬补丁或别人的 Pro dylib 负责）。
本件只解决“CloudKit 启动崩溃”，复现别人 Tg dylib 的「运行时伪造 entitlements + 容器重定向」手法。

> 本仓不替你编译（我们也编不了 iOS）。下面给**两套可直接编译的源码** + 编译 + 注入 + 重签步骤。

## 0. 文件清单
- `ysfakeck.h`        —— 公共辅助：伪 entitlements 字典 + 本地容器发现（两套源码共用）
- `Tweak.x`          —— **Logos 版**（Theos），最省事，推荐
- `inject_cloudkit.m` —— **纯 ObjC + <substrate.h> 版**（不依赖 Logos；可 Theos 也可裸 clang）
- `Makefile`         —— Theos 配置（默认编 Tweak.x）
- `control`          —— Theos 打包元数据
- `Makefile.clang`   —— 不装 Theos 时的裸 clang 命令
- `README_INJECT.md` —— 本文

## 1. 核心 hook 思路（对应别人 Tg dylib，已据 OTHERS_DYLIB_DEEPDIVE.md 复现）
分三层，**任意一层生效即可救活启动**：

A. **伪造权限（主）**
   - `-[CKEntitlements initWithEntitlementsDict:]`：把传入的权限字典与伪字典合并（缺的补上），
     使 CloudKit 认为本进程拥有 `com.apple.developer.icloud-services=[CloudKit,CloudDocuments]`、
     `icloud-container-environment=Production`、`icloud-container-identifiers=[iCloud.com.lxm.ysbrowser]`。
   - `+[CKEntitlements entitlementsForCurrentProcess]`（名字随 SDK 变，代码里列了几个候选）：直接返回伪字典。
   - `-[CKContainer _setupWithContainerID:options:]`：用 @try/@catch 吞掉权限缺失抛的异常，允许容器构造。
   → CloudKit 初始化链（含 `CKSDKVersion` 的 dispatch_once）看到权限齐全，不再抛未捕获异常。

B. **容器重定向（辅）**
   - `-[NSUserDefaults initWithSuiteName:]`：group./iCloud 前缀的 suite 重定向到 standardUserDefaults。
   - `+[NSUbiquitousKeyValueStore defaultStore]`：原返回 nil 时给本地占位实例。
   - `ysfakeck.h` 的 `YSLocalContainerURL()`：优先用重签后真实可用的 App Group 目录，否则沙盒 Library/YSFakeCloud。

C. **兜底禁用（保底，A 失效时启用）**
   若 SDK27 下 CloudKit 私有 selector 对不上（CloudKit 实现随版本变动），直接让 **YSKit 的 iCloud 启动入口空返回**：
   - ObjC 方法：`uuidsOfUserDevices_iCloudInit` / `_iCloudSync` —— `%hook` 其所在类，返回 nil/void（见 Tweak.x 末尾）。
   - Swift 静态 `getRecordData(...)` —— **用符号名，不要用偏移**：
     ```
     nm -arch arm64 YSKit | grep -i getRecordData      # 取 mangled 名，形如 $s5YSKit...getRecordData...
     ```
     再用 `dlsym(RTLD_DEFAULT, "<mangled>")` + `MSHookFunction(sym, my_impl, &orig)` 让它返回 nil。
   这层等价于我们之前的硬补丁 v5/v6（iCloudInit/iCloudSync/getRecordData 早退），100% 能止崩，只是不保留“本地假 iCloud”。

## 2. 为什么不照搬老偏移（SDK27 注意）
别人的 dylib 是针对旧版本(SDK26/Foundation 4040/CloudKit 2300)编译的；**类的内部布局、私有方法、Swift mangling
在 SDK27 都可能变**。因此本源码：
- CloudKit/Foundation 一律按**类名 + selector 名**在运行时 `objc_getClass` / `sel_registerName` 动态解析，不写死偏移；
- Swift 符号一律用 `dlsym` + mangled 名在你本机 `nm` 实测获取，不用硬编码地址。

## 3. 如何定位“承载 iCloud 的 YSKit 类名”（给 C1 用）
```
# 列出 YSKit 里带 iCloud 的 ObjC 方法及其所属类
nm -arch arm64 YSKit | grep -i iCloud
# 或 class-dump（iOS 版）/ ipsw / jtool2 -d objc YSKit | grep -i iCloud
```
找到形如 `-[XxxManager uuidsOfUserDevices_iCloudInit]` 的类名，填到 Tweak.x / inject_cloudkit.m 的 C1 处。

## 4. 编译
### 4a. Theos（推荐）
```
# 装 Theos: https://theos.dev  （macOS/Linux 皆可，需 iOS SDK）
export THEOS=~/theos
cd inject_dylib_src
make                       # 默认编 Tweak.x -> 得到 ysfakeck.dylib（在 .theos/obj/ 下）
# 想用纯 ObjC 版：把 Makefile 里 ysfakeck_FILES 改成 inject_cloudkit.m
```
### 4b. 裸 clang（不装 Theos）
```
# 需 Xcode iOS SDK + CydiaSubstrate 头(substrate.h)与库(libsubstrate.tbd)
cd inject_dylib_src
make -f Makefile.clang SUBSTRATE_INC=/path/substrate SUBSTRATE_LIB=/path/substrate
# 产物 ysfakeck.dylib，install_name 已设为 @executable_path/ysfakeck.dylib
```

## 5. 注入到 YSBrowser
```
# 1) 取得 insert_dylib: https://github.com/tyilo/insert_dylib
# 2) 把 ysfakeck.dylib 拷到 .app 根（与主程序 YSBrowser 同级）
cp ysfakeck.dylib Payload/YSBrowser.app/ysfakeck.dylib
# 3) 给主程序追加一条 @executable_path 的 LC_LOAD_DYLIB（放在最前，确保早于 CloudKit 用到之前加载）
insert_dylib --weak --all-yes \
  @executable_path/ysfakeck.dylib \
  Payload/YSBrowser.app/YSBrowser \
  Payload/YSBrowser.app/YSBrowser
# 若你也用别人的 libsubstrate.dylib，一并放进 .app 根并同样注入；
# 用 Theos 编出来的 dylib 已链接 substrate 桩，运行时会解析到随包的 libsubstrate。
```
> 顺序建议：ysfakeck.dylib 的 LC_LOAD_DYLIB 要排在 CloudKit.framework 之前（insert_dylib 默认插在末尾，
> 但 dylib 的 `constructor` 仍会在 UIApplicationMain/CloudKit 首次使用前执行，通常足够；若仍偶发，
> 可手动把该 load command 前移，或在 constructor 里不依赖加载顺序，只靠“首次使用前已 hook”）。

## 6. Apple ID 重签注意
- **dylib 必须随主 app 一起用你的 Apple ID 证书签名**：AltStore/Sideloadly 会对 .app 内所有 Mach-O
  （主程序 + Frameworks + PlugIns + 你加的 ysfakeck.dylib/libsubstrate.dylib）逐个重签。确保它们都在 .app 内。
- 路径用 `@executable_path/ysfakeck.dylib`（放 .app 根），不要用 /usr/lib 之类越狱路径。
- 重签会**剥掉**二进制里拿不到的 entitlements（CloudKit/iCloud/app-groups）——这正是本 dylib 要在运行时补回“假的”的原因，彼此不冲突。
- 个人证书 7 天过期属正常；用 AltStore 自动续签。
- iCloud 真机跨设备同步在个人证书下**仍不可用**（Apple 后端限制）；本 dylib 只保证“不因此崩 + 本地可跑”。

## 7. 验证
装好后用 Console.app（或 idevicesyslog）过滤 `[ysfakeck]`：
能看到 “注入伪权限/本地容器/hooked …” 日志即说明 hook 生效；App 不再启动秒退即成功。
若仍崩，看崩溃栈是否还在 CKSDKVersion——是则启用第 C 层兜底（最稳）。
