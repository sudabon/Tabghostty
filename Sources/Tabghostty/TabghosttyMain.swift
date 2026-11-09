// Tabghostty のエントリポイント。アプリ本体は TabghosttyApp にある（タイトルの導出などをテストできるように）。
import TabghosttyApp

@main
@MainActor
enum TabghosttyMain {
    static func main() {
        AppDelegate.run()
    }
}
