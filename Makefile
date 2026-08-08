SHELL := /bin/bash
SCHEME := MacVital
PROJECT := MacVital.xcodeproj
CONFIG ?= Debug
DERIVED := build

# Local loops do not need a Developer ID — requiring one means nobody can build
# the project without owning a cert. But they do need to be *signed*, ad-hoc.
#
# The previous setting here was `CODE_SIGNING_ALLOWED=NO`, which made Xcode skip
# bundle signing entirely: the Mach-O still carried the linker's own ad-hoc
# signature (so `codesign -dv` cheerfully printed a CDHash) while the .app had
# no `_CodeSignature` and therefore **no designated requirement at all**.
#
# That is not a cosmetic difference. TCC records a permission grant against the
# app's designated requirement, so a bundle without one can be added to Full
# Disk Access, show an enabled switch, and still never match the running
# process. The app is denied forever and nothing the user does fixes it.
#
# `CODE_SIGN_IDENTITY=-` signs the bundle ad-hoc, which yields a real
# (cdhash-based) requirement. Grants then stick until the next rebuild changes
# the hash — for a stable requirement that survives rebuilds you need an actual
# certificate; see README.
ADHOC := CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
         DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=

# Tests deliberately stay unsigned, and this is not an oversight to be tidied up
# later. A signature buys exactly one thing — a designated requirement for TCC
# to record a grant against — and the test bundle never asks for a permission.
# Requiring one just makes `xcodebuild test` fail, because the XCTest bundle has
# no Info.plist of its own.
UNSIGNED := CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=

# A self-signed code-signing certificate from Keychain Access. Gives a stable
# designated requirement, so TCC grants survive a rebuild — see docs/SIGNING.md.
IDENTITY ?= MacVital Local

APP := /Applications/MacVital.app

.PHONY: help project build build-signed build-selfsigned test run install \
        verify-signing check-team clean archive lint helper-log icon

help:
	@echo "make project        - 用 XcodeGen 生成 $(PROJECT)"
	@echo "make build          - 编译，ad-hoc 签名（CONFIG=Debug|Release）"
	@echo "make build-selfsigned - 用自签名证书编译（IDENTITY=证书名）"
	@echo "make build-signed   - 用 xcconfig 里的 Developer ID 签名编译"
	@echo "make install        - 安装到 $(APP) 并校验签名"
	@echo "make verify-signing - 检查某个 .app 是否真的签过（APP=路径）"
	@echo "make test           - 跑 MacVitalKit 单元测试（不签名，见 Makefile 注释）"
	@echo "make run            - 编译并启动 App（特权助手不可用）"
	@echo "make archive        - Release 归档，供签名/公证"
	@echo "make helper-log     - 跟踪特权助手日志"
	@echo "make clean          - 清理生成物"

project:
	@command -v xcodegen >/dev/null || { echo "缺少 xcodegen：brew install xcodegen"; exit 1; }
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) $(ADHOC) build

# Signs with a self-signed certificate. Buys a stable designated requirement —
# so a Full Disk Access grant survives rebuilds — but NOT a working helper: a
# self-signed cert carries no team identifier, so `CodeRequirement` still comes
# back nil and the helper exits by design. See docs/SIGNING.md.
build-selfsigned: project
	@security find-identity -v -p codesigning | grep -q "$(IDENTITY)" || { \
		echo "钥匙串里找不到代码签名证书 \"$(IDENTITY)\"。"; \
		echo "创建步骤见 docs/SIGNING.md，或用 IDENTITY=\"证书名\" 指定别的。"; exit 1; }
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) CODE_SIGN_IDENTITY="$(IDENTITY)" \
		CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build

# The team ID lives in two files and they must agree: the xcconfig drives code
# signing, the helper's Info.plist drives SMAuthorizedClients. Disagreement
# makes the helper reject every connection with no obvious error, so check it
# here rather than letting it become a debugging session.
check-team:
	@xc=$$(sed -n 's/^MACVITAL_TEAM_ID *= *//p' Config/Shared.xcconfig | tr -d ' '); \
	pl=$$(sed -n 's/.*subject.OU\] *= *"\([A-Z0-9]*\)".*/\1/p' Sources/MacVitalHelper/Info.plist); \
	if [ "$$xc" = "ABCDE12345" ]; then \
		echo "MACVITAL_TEAM_ID 还是占位值 ABCDE12345。"; \
		echo "改 Config/Shared.xcconfig 和 Sources/MacVitalHelper/Info.plist，见 docs/SIGNING.md。"; exit 1; fi; \
	if [ "$$xc" != "$$pl" ]; then \
		echo "team ID 不一致：xcconfig=$$xc  Info.plist=$$pl"; \
		echo "两处必须相同，否则助手会拒绝每一个连接。"; exit 1; fi; \
	echo "team ID 一致：$$xc"

# Needs a Developer ID Application identity in the keychain and the real team
# ID in Config/Shared.xcconfig. This is the only way to exercise the Helper:
# the XPC requirement strings are derived from the running binary's own team
# identifier, so an unsigned build cannot talk to it.
build-signed: check-team project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) build

test: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) $(UNSIGNED) test

run: build
	open $(DERIVED)/Build/Products/$(CONFIG)/MacVital.app

# `ditto` rather than `cp -R` — it preserves the extended attributes a code
# signature depends on. Verifies afterwards, because an app whose bundle is
# unsigned can never be granted Full Disk Access no matter what the user does
# in System Settings, and that failure is otherwise silent.
install:
	@test -d "$(DERIVED)/Build/Products/$(CONFIG)/MacVital.app" || { \
		echo "没有 $(CONFIG) 构建产物，先跑 make build CONFIG=$(CONFIG)"; exit 1; }
	pkill -f "MacVital.app/Contents/MacOS/MacVital" 2>/dev/null || true
	rm -rf "$(APP)"
	ditto "$(DERIVED)/Build/Products/$(CONFIG)/MacVital.app" "$(APP)"
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$(APP)"
	@$(MAKE) --no-print-directory verify-signing
	@echo
	@echo "已安装到 $(APP)"
	@echo "注意：可执行文件的哈希变了，之前的完整磁盘访问权限授权已失效。"
	@echo "请到「系统设置 → 隐私与安全性 → 完整磁盘访问权限」用「−」移除旧条目，"
	@echo "再用「+」重新添加 $(APP)，然后重启 App。（用证书签名可免除这一步，见 docs/SIGNING.md）"

# The check that would have saved a long debugging session: a bundle can carry
# a linker ad-hoc signature on its Mach-O — so `codesign -dv` prints a CDHash
# and looks fine — while having no `_CodeSignature` and therefore no designated
# requirement at all. TCC has nothing to record a grant against, so the app is
# permanently denied.
verify-signing:
	@codesign --verify --deep --strict "$(APP)" 2>&1 | grep -q "not signed at all" && { \
		echo "✗ $(APP) 的包没有签名 —— 它永远无法获得完整磁盘访问权限。"; \
		echo "  见 docs/SIGNING.md。"; exit 1; } || true
	@codesign --verify --deep --strict "$(APP)" || { echo "✗ 签名校验失败"; exit 1; }
	@echo "✓ 签名有效：$$(codesign -d -r- "$(APP)" 2>&1 | sed -n 's/^# designated => //p')"

archive: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-archivePath $(DERIVED)/MacVital.xcarchive archive

# Regenerate the app icon from Tools/MakeAppIcon.swift. The .appiconset holds
# only rendered PNGs, so without this the artwork is unreproducible — editing
# the icon means editing the script, not the images.
ICONSET := Sources/MacVital/Resources/Assets.xcassets/AppIcon.appiconset
icon:
	@swift Tools/MakeAppIcon.swift $(ICONSET)/icon_1024.png
	@for px in 16 32 64 128 256 512; do \
		sips -Z $$px $(ICONSET)/icon_1024.png --out $(ICONSET)/icon_$$px.png >/dev/null; \
	done
	@echo "图标已重新生成，运行 make build 生效"

# The helper writes to /var/log; launchd also captures crashes in the unified log.
helper-log:
	log stream --predicate 'process == "com.macvital.helper" OR subsystem == "com.macvital.MacVital"' --level info

clean:
	rm -rf $(DERIVED) $(PROJECT)
