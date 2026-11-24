import XCTest

final class LocalizationUITests: XCTestCase {
    private func launch(_ fixture: String? = nil, layout: String? = nil, language: String = "ru") -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_SYNC_FIXTURE"] = "available"
        if let fixture { app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = fixture }
        if let layout { app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = layout }
        app.launch()
        return app
    }
    private func attach(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = title; image.lifetime = .keepAlways; add(image)
    }
    private func assertVisible(_ element: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertTrue(element.isHittable, element.label)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX - 1)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 1)
    }
    func testRussianHomeSettingsAndEnglishRelaunch() {
        let app = launch()
        assertVisible(app.textFields["Ссылка-приглашение"], app: app)
        XCTAssertTrue(app.buttons["Войти в джем"].exists)
        assertVisible(app.textFields["name.input"], app: app)
        XCTAssertEqual(app.textFields["name.input"].label, "Ваше имя")
        XCTAssertTrue(app.buttons["home.assistant"].exists)
        XCTAssertFalse(app.buttons["Выбрать свой контакт"].exists)
        app.buttons["Настройки"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings.assistant"].exists)
        XCTAssertTrue(app.buttons["settings.websites"].exists)
        app.buttons["settings.websites"].tap()
        XCTAssertTrue(app.staticTexts["Совместимый сайт встреч"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))
        attach(app, "Russian settings")
        app.navigationBars.buttons["Готово"].tap()
        attach(app, "Russian home")
        app.terminate()
        let english = launch(language: "en")
        XCTAssertTrue(english.textFields["Invitation link"].waitForExistence(timeout: 10))
        XCTAssertTrue(english.buttons["Settings"].exists)
        XCTAssertTrue(english.buttons["home.assistant"].exists)
    }
    func testRussianConversationAndContentStayDistinctAcrossRotation() {
        let app = launch("conversation")
        defer { XCUIDevice.shared.orientation = .portrait }
        let modes = app.segmentedControls["Режим беседы"]
        XCTAssertTrue(modes.waitForExistence(timeout: 10))
        XCTAssertTrue(modes.buttons["Чат"].isSelected)
        XCTAssertTrue(app.buttons["Отправить сообщение"].exists)
        let draft = app.textViews["Сообщение в чат"]
        draft.tap(); draft.typeText("Ani — проверка %@")
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            assertVisible(app.buttons["Выйти"], app: app)
            assertVisible(app.buttons["Закрыть беседу"], app: app)
            XCTAssertTrue((draft.value as? String)?.contains("Ani — проверка %@") == true)
        }
        app.buttons["Отправить сообщение"].tap()
        let hideKeyboard = app.keyboards.buttons["Скрыть клавиатуру"]
        if hideKeyboard.exists { hideKeyboard.tap() }
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        modes.buttons["Текст"].tap()
        XCTAssertTrue(app.textViews["Расшифровка джема"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["Расшифровка джема"].value as? String)?.contains("We will meet Friday at six thirty.") == true)
        modes.buttons["Пропущено"].tap()
        XCTAssertTrue(app.staticTexts["Другой звонок"].waitForExistence(timeout: 10))
        attach(app, "Russian missed sections")
    }
    func testRussianCallAndParticipantControlsFitRotation() {
        let app = launch(layout: "rock")
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            for title in ["Выйти", "Включить микрофон", "Включить видео", "Транслировать экран", "Другие действия"] {
                assertVisible(app.buttons[title], app: app)
            }
        }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Музыканты")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Музыканты"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Rock QA (вы)"].exists)
        XCTAssertTrue(app.staticTexts["Микрофон выкл. · Видео выкл."].exists)
        attach(app, "Russian participants")
    }

    func testGuestConversationCaptionsFitLandscapeSafeAreaAndPortrait() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["ru", "en"] {
            let app = launch("guest-call", language: language)
            let russian = language == "ru"
            let chat = app.buttons[russian ? "Чат" : "Chat"]
            XCTAssertTrue(chat.waitForExistence(timeout: 10))
            chat.tap()
            let modes = app.segmentedControls["Conversation mode"]
            XCTAssertTrue(modes.waitForExistence(timeout: 5))
            modes.buttons[russian ? "Пропущено" : "Catch up"].tap()
            for orientation: UIDeviceOrientation in [.landscapeLeft, .landscapeRight, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let strip = app.otherElements["Conversation call controls"]
                XCTAssertTrue(strip.waitForExistence(timeout: 5))
                // Content stays wide enough after the phone's landscape safe-area inset.
                XCTAssertGreaterThanOrEqual(modes.frame.width, 288)
                XCTAssertTrue(modes.buttons[russian ? "Пропущено" : "Catch up"].isSelected)
                for label in [russian ? "Включить микрофон" : "Unmute microphone",
                              russian ? "Включить видео" : "Start video",
                              russian ? "Выйти" : "Leave"] {
                    let button = strip.buttons[label]
                    XCTAssertTrue(button.isHittable, label)
                    XCTAssertTrue(strip.frame.contains(button.frame), label)
                    XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                    XCTAssertGreaterThanOrEqual(button.frame.height, 44)
                }
                XCTAssertEqual(strip.buttons[russian ? "Включить микрофон" : "Unmute microphone"].value as? String,
                               russian ? "Микрофон выключен" : "Microphone off")
                XCTAssertTrue(strip.staticTexts[russian ? "Микр." : "Mic"].exists)
                XCTAssertTrue(strip.staticTexts[russian ? "Камера" : "Cam"].exists)
                attach(app, "Conversation captions \(language) \(orientation.rawValue)")
            }
            app.terminate()
        }
    }
    func testRussianSharingPreviewUsesTranslatedControls() throws {
        let app = launch(layout: "local-share")
        let preview = app.buttons["Увеличить предпросмотр трансляции"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Остановить свою трансляцию экрана"].exists)
        preview.tap()
        assertVisible(app.buttons["Закрыть предпросмотр"], app: app)
        assertVisible(app.buttons["Остановить трансляцию"], app: app)
        let refresh = try XCTUnwrap(app.buttons.matching(identifier: "Обновить предпросмотр")
            .allElementsBoundByIndex.first { $0.isHittable })
        assertVisible(refresh, app: app)
        attach(app, "Russian local sharing preview")
    }

    func testAssistantSettingsMeetingParamsChangeOnSingleTap() {
        let app = launch(language: "en")
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let assistantLink = app.buttons["settings.assistant"]
        XCTAssertTrue(assistantLink.waitForExistence(timeout: 5))
        assistantLink.tap()

        XCTAssertTrue(app.navigationBars["Assistant & Sync"].waitForExistence(timeout: 5))
        // Wait past HomeInteractionState's 180ms settle window to reproduce the idle sheet state.
        Thread.sleep(forTimeInterval: 0.4)

        let modePickers: [(id: String, candidateA: String, candidateB: String)] = [
            ("assistant.settings.foregroundMode", "Follow", "Mentions"),
            ("assistant.settings.backgroundMode", "Follow", "Participate"),
            ("assistant.settings.silencedMode", "Participate", "Off"),
            ("assistant.settings.replyChannel", "Voice reply", "Chat message")
        ]

        for entry in modePickers {
            let picker = app.buttons[entry.id].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "Missing picker \(entry.id)")
            XCTAssertTrue(picker.isHittable, "Picker not hittable: \(entry.id)")
            let current = picker.value as? String
            let target = (current == entry.candidateA) ? entry.candidateB : entry.candidateA

            // Tap once on the leading label area to verify full-row hit testing and single-tap opening.
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

            let option = app.buttons[target].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3), "Menu option '\(target)' did not appear after one tap on \(entry.id)")
            option.tap()

            XCTAssertEqual(picker.value as? String, target, "Picker \(entry.id) did not update on first option tap")
        }

        // Navigate back to Settings and dismiss, then verify the second entry point via Assistant Hub.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let doneButton = app.navigationBars.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()

        let hubButton = app.buttons["home.assistant"]
        XCTAssertTrue(hubButton.waitForExistence(timeout: 5))
        hubButton.tap()

        let hubSettings = app.buttons["workspace.hub.settings"]
        XCTAssertTrue(hubSettings.waitForExistence(timeout: 5))
        hubSettings.tap()

        XCTAssertTrue(app.navigationBars["Assistant & Sync"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.4)

        let backgroundPicker = app.buttons["assistant.settings.backgroundMode"].firstMatch
        XCTAssertTrue(backgroundPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(backgroundPicker.isHittable)
        let initialBg = backgroundPicker.value as? String
        let nextBg = (initialBg == "Mentions") ? "Follow" : "Mentions"
        backgroundPicker.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

        let nextBgOption = app.buttons[nextBg].firstMatch
        XCTAssertTrue(nextBgOption.waitForExistence(timeout: 3), "Menu option '\(nextBg)' did not appear after one tap in hub sheet")
        nextBgOption.tap()
        XCTAssertEqual(backgroundPicker.value as? String, nextBg)
    }
}
