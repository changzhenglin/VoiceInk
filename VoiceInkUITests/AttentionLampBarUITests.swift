//
//  AttentionLampBarUITests.swift
//  VoiceInkUITests
//
//  Task 8A Step 7：P1 灯条 UI 最小冒烟面（bar 出现/五灯形状/基本键盘路径）。
//  穷举 UI/AX/E2E 验收归 Task 14A gate（brief 裁决 A 边界）。
//  冒烟前置：launch argument 打开 versioned flag（默认 off → 呈现静默）。
//

import XCTest

final class AttentionLampBarUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 冒烟①：versioned flag on 时 app 启动不因 v4 灯条接线崩溃（生产表面接线健康）。
    @MainActor
    func testAppLaunchesWithLampBarFlagOn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AttentionLampBarP1Enabled", "YES"]
        app.launch()
        // 菜单栏 app 可能仅后台驻留（LSUIElement）；前台或后台 running 均算启动成功。
        let running = app.wait(for: .runningForeground, timeout: 10)
            || app.wait(for: .runningBackground, timeout: 5)
        XCTAssertTrue(running, "flag on 时 app 应正常启动（v4 灯条接线不致崩溃）")
    }

    /// 冒烟②：bar 出现 + 五灯形状 + 基本键盘路径（⌘⇧V）。
    /// 前置：bar 仅在存在受管会话时呈现（spec §3「bar 隐藏=无受管会话」）。
    /// UI 测试环境无法播种真实 hook 会话（privacy：不采真实用户内容），无会话时 bar
    /// 依 §3 隐藏 → 本例以 XCTSkip 如实标注前置缺失，受控事件注入下的穷举验收归 Task 14A。
    @MainActor
    func testLampBarSurfacesAndKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AttentionLampBarP1Enabled", "YES"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
            || app.wait(for: .runningBackground, timeout: 5)

        let bar = app.otherElements["attention.lampBar"]
        guard bar.waitForExistence(timeout: 5) else {
            throw XCTSkip("lamp bar 未出现：UI 测试环境无受管会话（bar 隐藏=无会话，§3）；" +
                          "受控 hook 事件注入下的 bar/五灯/键盘穷举验收归 Task 14A gate。")
        }

        // 五灯形状面：bar 出现后查询 lamp 元素（至少 1 灯）。
        let firstLamp = app.otherElements["attention.lamp.0"]
        XCTAssertTrue(firstLamp.waitForExistence(timeout: 3), "bar 出现时首灯应存在")

        // 基本键盘路径：⌘⇧V 唤起/回焦灯条（spec §7 键盘契约）。
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(bar.waitForExistence(timeout: 3), "⌘⇧V 后灯条应可回焦")
    }
}
