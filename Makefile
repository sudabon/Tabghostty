VENDOR_XCFRAMEWORK := Vendor/GhosttyVt.xcframework

# Swift Testing のマクロプラグインの場所（使っている toolchain から求める）。
# Command Line Tools の Swift 6.4（swiftbuild）では、`swift build` と `swift test` を交互に実行すると
# TestingMacros プラグインが見つからずにテストのコンパイルが失敗することがあるため、明示的に渡す。
SWIFT_TESTING_PLUGIN_DIR := $(shell d="$$(dirname "$$(xcrun --find swift 2>/dev/null)")/../lib/swift/host/plugins/testing"; [ -d "$$d" ] && cd "$$d" && pwd)
SWIFT_TEST_FLAGS := $(if $(SWIFT_TESTING_PLUGIN_DIR),-Xswiftc -plugin-path -Xswiftc $(SWIFT_TESTING_PLUGIN_DIR))

.PHONY: deps build test check-deps

## libghostty-vt を取得・検証して Vendor/ に置く
deps:
	bash scripts/fetch-libghostty.sh

check-deps:
	@test -d $(VENDOR_XCFRAMEWORK) || { \
		echo "libghostty-vt が見つかりません（$(VENDOR_XCFRAMEWORK)）。先に \`make deps\` を実行してください。" >&2; \
		exit 1; }

## 全ターゲットをビルドする
build: check-deps
	swift build

## テストを実行する
test: check-deps
	swift test $(SWIFT_TEST_FLAGS)
