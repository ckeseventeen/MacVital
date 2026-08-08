SHELL := /bin/bash
SCHEME := MacVital
PROJECT := MacVital.xcodeproj
# Release, not Debug, and deliberately so: every target here that matters ends
# with the product in /Applications, and a Debug product does not belong there.
# It carries MacVital.debug.dylib and __preview.dylib, which only mean anything
# under Xcode. Debugging happens in Xcode; this file builds things to install.
# `CONFIG=Debug` still works for anyone who wants it.
CONFIG ?= Release
DERIVED := build

# Tests build into their own derived data, and this is load-bearing.
#
# Sharing `build/` with the app meant `make test` — which builds unsigned, by
# design, see UNSIGNED below — relinked the very executable `make build` had
# just signed, leaving a bundle whose stale `_CodeSignature` no longer matched
# its Mach-O (`code has no resources but signature indicates they must be
# present`).
#
# That bundle is worse than an unsigned one. It still declares
# CFBundleIdentifier com.macvital.MacVital, so macOS can resolve the identifier
# to *it* rather than to the installed copy, and every TCC requirement check
# then fails — the app is denied Screen Recording no matter what the user
# toggles in System Settings, and nothing in the UI can explain why.
DERIVED_TEST := build-test

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
PRODUCT := $(DERIVED)/Build/Products/$(CONFIG)/MacVital.app

.PHONY: help project build build-signed build-selfsigned test run install \
        verify-signing check-team clean archive lint helper-log icon

help:
	@echo "make project        - 用 XcodeGen 生成 $(PROJECT)"
	@echo "make build          - 编译，ad-hoc 签名（CONFIG=Release|Debug，默认 Release）"
	@echo "make build-selfsigned - 用自签名证书编译（IDENTITY=证书名）"
	@echo "make build-signed   - 用 xcconfig 里的 Developer ID 签名编译"
	@echo "make install        - 安装到 $(APP) 并校验签名（默认 Release）"
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
	@# `-v` (valid identities only) is deliberately NOT used here. A self-signed
	@# root created in Certificate Assistant reports CSSMERR_TP_NOT_TRUSTED,
	@# which drops it from the `-v` list — and the first version of this guard
	@# therefore insisted the certificate did not exist while it sat right
	@# there in the keychain.
	@#
	@# Trust is irrelevant to what this build wants. Trust governs *verifying*
	@# a signature (Gatekeeper); it does not gate *making* one. codesign signs
	@# happily with an untrusted identity, and the resulting requirement is
	@# `certificate leaf = H"..."` — pinned to the certificate rather than the
	@# executable's hash, which is the entire point: TCC grants then survive a
	@# rebuild.
	@security find-identity -p codesigning | grep -q "$(IDENTITY)" || { \
		echo ""; \
		echo "钥匙串里没有代码签名证书 \"$(IDENTITY)\"。"; \
		echo "这个证书要在图形界面里建，命令行代替不了（约两分钟，只做一次）："; \
		echo ""; \
		echo "  1. 打开「钥匙串访问」（macOS 15 起已不在「实用工具」里）："; \
		echo "     open \"/System/Library/CoreServices/Applications/Keychain Access.app\""; \
		echo "  2. 点最左边的应用菜单「钥匙串访问」→ 证书助理 → 创建证书…"; \
		echo "  3. 名称：$(IDENTITY)"; \
		echo "     身份类型：自签名根证书"; \
		echo "     证书类型：代码签名"; \
		echo "  4. 一路「继续」，钥匙串选「登录」"; \
		echo ""; \
		echo "建好后跑这个确认："; \
		echo "  security find-identity -p codesigning"; \
		echo ""; \
		echo "已经有别的证书就用 IDENTITY=\"你的证书名\" 指定。说明见 docs/SIGNING.md。"; \
		echo ""; \
		exit 1; }
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

# `-scheme MacVitalKitTests`, not $(SCHEME): the app scheme builds the app, and
# an unsigned MacVital.app is the one artifact this project must never leave
# lying around. See the scheme's comment in project.yml.
test: project
	xcodebuild -project $(PROJECT) -scheme MacVitalKitTests -configuration Debug \
		-derivedDataPath $(DERIVED_TEST) $(UNSIGNED) test

run: build
	open $(DERIVED)/Build/Products/$(CONFIG)/MacVital.app

# `ditto` rather than `cp -R` — it preserves the extended attributes a code
# signature depends on. Verifies on both sides of the copy: an app whose bundle
# does not verify can never hold a TCC grant no matter what the user does in
# System Settings, and that failure is otherwise completely silent.
install:
	@test -d "$(PRODUCT)" || { \
		echo "没有 $(CONFIG) 构建产物，先跑 make build CONFIG=$(CONFIG)"; \
		echo "（或 make build-selfsigned CONFIG=$(CONFIG)，授权能跨重编译保留）"; exit 1; }
	@if [ "$(CONFIG)" = "Debug" ]; then \
		echo "⚠ 正在把 Debug 产物装进 $(APP)：里面带着 MacVital.debug.dylib 和 __preview.dylib，"; \
		echo "  只在 Xcode 里有意义。日常用请 make build-selfsigned && make install。"; \
	fi
	@# Verify the *source* before it goes anywhere. Verifying only the installed
	@# copy — which is all this used to do — reports a broken bundle after it has
	@# already replaced a working one, and a bundle whose signature does not
	@# verify makes TCC fail every requirement check while the switch in System
	@# Settings still shows as on.
	@$(MAKE) --no-print-directory verify-signing APP="$(PRODUCT)"
	pkill -f "MacVital.app/Contents/MacOS/MacVital" 2>/dev/null || true
	rm -rf "$(APP)"
	ditto "$(PRODUCT)" "$(APP)"
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$(APP)"
	@$(MAKE) --no-print-directory verify-signing
	@echo
	@echo "已安装到 $(APP)（$(CONFIG)）"
	@# Only ad-hoc builds need the remove/re-add dance. Printing it after a
	@# certificate-signed install is how people end up doing it every time and
	@# concluding that signing changed nothing.
	@if codesign -d -r- "$(APP)" 2>&1 | grep -q 'cdhash'; then \
		echo; \
		echo "这是 ad-hoc 签名：requirement 绑的是可执行文件哈希，刚才重编译已让旧授权失效。"; \
		echo "请到「系统设置 → 隐私与安全性」把完整磁盘访问权限和屏幕录制里的旧条目用「−」移除，"; \
		echo "再用「+」重新添加 $(APP)，然后重启 App。"; \
		echo "（改用 make build-selfsigned 可以永久免除这一步，见 docs/SIGNING.md）"; \
	fi
	@# The failure mode this whole file is written around: a second bundle
	@# claiming the same identifier. macOS resolves com.macvital.MacVital to
	@# *some* bundle when checking a TCC requirement, and if it picks one whose
	@# requirement differs from the granted one, every check fails while the
	@# switch in System Settings still reads as on.
	@#
	@# Only a *differing* requirement is worth reporting. A second copy signed
	@# with the same certificate satisfies the same requirement, so it is
	@# harmless — and `make build` leaves one in build/ every single time.
	@installed=$$(codesign -d -r- "$(APP)" 2>&1 | sed -n 's/^#* *designated => //p'); \
	bad=$$(mdfind "kMDItemCFBundleIdentifier == 'com.macvital.MacVital'" 2>/dev/null \
		| grep -v "^$(APP)$$" \
		| while IFS= read -r other; do \
			req=$$(codesign -d -r- "$$other" 2>&1 | sed -n 's/^#* *designated => //p'); \
			[ "$$req" = "$$installed" ] || echo "$$other"; \
		done); \
	if [ -n "$$bad" ]; then \
		echo; \
		echo "⚠ 机器上还有 MacVital.app 声明同一个 bundle id，且签名 requirement 与刚装的这份不同："; \
		echo "$$bad" | sed 's/^/    /'; \
		echo "  系统可能拿它们去校验权限，表现就是权限勾了也没用。建议删掉。"; \
	fi

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
	@# Both spellings: ad-hoc prints "# designated => ", a certificate-signed
	@# bundle prints "designated => " with no comment marker. Matching only the
	@# first printed a cheerful "✓ 签名有效：" followed by nothing.
	@echo "✓ 签名有效：$$(codesign -d -r- "$(APP)" 2>&1 | sed -n 's/^#* *designated => //p')"

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
	rm -rf $(DERIVED) $(DERIVED_TEST) $(PROJECT)
