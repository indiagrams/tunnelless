// app/Project.swift — Tuist 4 manifest for the TailnetDemo template stub.
//
// 1:1 equivalent of app/project.yml. Both ship on `main`; bin/rename.sh's
// `--generator=tuist|xcodegen` flag (see #38) selects which one a fresh
// fork keeps post-rename. CI runs both via .github/workflows/pr.yml's
// 6-job matrix so any drift between the two manifests fails fast.
//
// When editing this file, also update app/project.yml (and vice versa).
// The CI matrix is the source of truth — both must produce a
// build-green TailnetDemo.xcodeproj.

import ProjectDescription

// MARK: - Shared settings

let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "MARKETING_VERSION": "0.0.1",
    "CURRENT_PROJECT_VERSION": "1",
    // DEVELOPMENT_TEAM is auto-substituted by bin/rename.sh --team-id
    // (auto-passed by bin/bootstrap-fork.rb from .bootstrap.env FASTLANE_TEAM_ID).
    "DEVELOPMENT_TEAM": "TEAM_ID_PLACEHOLDER",
    "CODE_SIGN_STYLE": "Automatic",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "NO",
    "GCC_TREAT_WARNINGS_AS_ERRORS": "NO",
]

// MARK: - iOS app

let iosInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "Tailnet Demo",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "UILaunchScreen": .dictionary([:]),
    "UIApplicationSceneManifest": .dictionary([
        "UIApplicationSupportsMultipleScenes": false,
    ]),
    "UISupportedInterfaceOrientations": .array([
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]),
    "UISupportedInterfaceOrientations~ipad": .array([
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]),
    "ITSAppUsesNonExemptEncryption": false,
]

let iosTarget = Target.target(
    name: "TailnetDemo-iOS",
    destinations: [.iPhone, .iPad],
    product: .app,
    bundleId: "com.indiagram.tailnetdemo",
    deploymentTargets: .iOS("17.0"),
    infoPlist: .extendingDefault(with: iosInfoPlist),
    sources: ["Shared/**", "iOS/**"],
    resources: [
        "iOS/Assets.xcassets",
        "Shared/PrivacyInfo.xcprivacy",
        "Shared/Localizable.xcstrings",
    ],
    entitlements: .file(path: "iOS/TailnetDemo.entitlements"),
    settings: .settings(base: [
        "PRODUCT_BUNDLE_IDENTIFIER": "com.indiagram.tailnetdemo",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "SUPPORTS_MACCATALYST": "NO",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.utilities",
        "INFOPLIST_KEY_NSHumanReadableCopyright": "TODO Copyright © 2026 <Your Org>. All rights reserved.",
    ])
)

// MARK: - macOS app

let macInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "Tailnet Demo",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
    "LSApplicationCategoryType": "public.app-category.utilities",
    "NSHumanReadableCopyright": "TODO Copyright © 2026 <Your Org>. All rights reserved.",
    "NSPrincipalClass": "NSApplication",
    // CFBundleIconName intentionally NOT set — its presence makes Sonoma+
    // prefer Assets.car AppIcon (which has actool's broken 4-size set).
    // The post-build script below installs the hand-rolled .icns instead.
    "CFBundleIconFile": "AppIcon",
    "ITSAppUsesNonExemptEncryption": false,
]

// Overwrites actool's broken 4-size .icns with the hand-rolled 10-size
// version. Tuist places `.post` scripts at the END of buildPhases (after
// Resources / Frameworks / Embed Frameworks) but before Code Sign — so
// the .icns gets overwritten *after* actool emits its broken version,
// and the signed bundle ships with the hand-rolled 10-size set.
let macIconScript: TargetScript = .post(
    script: """
    set -euo pipefail
    /bin/cp "$SCRIPT_INPUT_FILE_0" "$SCRIPT_OUTPUT_FILE_0"
    echo "Overwrote $SCRIPT_OUTPUT_FILE_0 with hand-rolled 10-size .icns"
    """,
    name: "Overwrite actool's broken AppIcon.icns with hand-rolled 10-size version",
    inputPaths: ["$(SRCROOT)/macOS/Resources/AppIcon.icns"],
    outputPaths: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AppIcon.icns"]
)

let macTarget = Target.target(
    name: "TailnetDemo-macOS",
    destinations: [.mac],
    product: .app,
    bundleId: "com.indiagram.tailnetdemo",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .extendingDefault(with: macInfoPlist),
    sources: [
        "Shared/**",
        // macOS/Resources/ holds the hand-rolled AppIcon.icns + source 1024 PNG.
        // Excluded here because the post-build script copies the .icns into
        // the .app over actool's broken 4-size version.
        .glob("macOS/**", excluding: ["macOS/Resources/**"]),
    ],
    resources: [
        "macOS/Assets.xcassets",
        "Shared/PrivacyInfo.xcprivacy",
        "Shared/Localizable.xcstrings",
    ],
    entitlements: .file(path: "macOS/TailnetDemo.entitlements"),
    scripts: [macIconScript],
    settings: .settings(base: [
        "PRODUCT_BUNDLE_IDENTIFIER": "com.indiagram.tailnetdemo",
        // Suppress actool's auto-injection of CFBundleIconName=AppIcon.
        // Empty value = actool emits Assets.car as before but does not set
        // the key, so macOS reads CFBundleIconFile → our hand-rolled .icns.
        "ASSETCATALOG_COMPILER_APPICON_NAME": "",
    ])
)

// MARK: - UI test targets

let iosUITestTarget = Target.target(
    name: "TailnetDemoUITests",
    destinations: [.iPhone, .iPad],
    product: .uiTests,
    bundleId: "com.indiagram.tailnetdemo.uitests",
    deploymentTargets: .iOS("17.0"),
    infoPlist: .default,
    sources: ["UITests/**", "Shared/AccessibilityIdentifiers.swift"],
    dependencies: [.target(name: "TailnetDemo-iOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "TailnetDemo-iOS",
        // SnapshotHelper.swift is fastlane-shipped and predates Swift 6's
        // strict-by-default concurrency model. Pin this target to Swift 5
        // mode so the file compiles unmodified — base SWIFT_VERSION is 6.0.
        "SWIFT_VERSION": "5.9",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
    ])
)

let macUITestTarget = Target.target(
    name: "TailnetDemoMacOSUITests",
    destinations: [.mac],
    product: .uiTests,
    bundleId: "com.indiagram.tailnetdemo.macuitests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: ["MacOSUITests/**", "Shared/AccessibilityIdentifiers.swift"],
    dependencies: [.target(name: "TailnetDemo-macOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "TailnetDemo-macOS",
        // AppStoreScreenshotTests overrides XCTestCase.setUpWithError /
        // tearDownWithError in a @MainActor class — Swift 6 errors on
        // main-actor-isolated mutation in nonisolated overrides. Pin this
        // target to Swift 5 mode (parallel to iosUITestTarget).
        "SWIFT_VERSION": "5.9",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
    ])
)

// MARK: - Unit test targets (sanity tests; forks should add real tests here)

let iosUnitTestTarget = Target.target(
    name: "TailnetDemoTests",
    destinations: [.iPhone, .iPad],
    product: .unitTests,
    bundleId: "com.indiagram.tailnetdemo.tests",
    deploymentTargets: .iOS("17.0"),
    infoPlist: .default,
    sources: ["Tests/**"],
    dependencies: [.target(name: "TailnetDemo-iOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "TailnetDemo-iOS",
    ])
)

let macUnitTestTarget = Target.target(
    name: "TailnetDemoMacOSTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "com.indiagram.tailnetdemo.mactests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: ["MacOSTests/**"],
    dependencies: [.target(name: "TailnetDemo-macOS")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "TailnetDemo-macOS",
    ])
)

// MARK: - Schemes

let iosScheme: Scheme = .scheme(
    name: "TailnetDemo-iOS",
    shared: true,
    // NB: only the main app target — UI tests live in testAction only.
    // Including TailnetDemoUITests here would compile it during plain
    // `xcodebuild build` and trip strict-concurrency errors that the
    // per-target SWIFT_STRICT_CONCURRENCY=minimal override can't suppress.
    buildAction: .buildAction(targets: ["TailnetDemo-iOS"]),
    testAction: .targets(
        ["TailnetDemoUITests", "TailnetDemoTests"],
        configuration: .debug
    ),
    runAction: .runAction(configuration: .debug, executable: "TailnetDemo-iOS"),
    archiveAction: .archiveAction(configuration: .release)
)

let macScheme: Scheme = .scheme(
    name: "TailnetDemo-macOS",
    shared: true,
    buildAction: .buildAction(targets: ["TailnetDemo-macOS"]),
    testAction: .targets(
        ["TailnetDemoMacOSUITests", "TailnetDemoMacOSTests"],
        configuration: .debug
    ),
    runAction: .runAction(configuration: .debug, executable: "TailnetDemo-macOS"),
    archiveAction: .archiveAction(configuration: .release)
)

// MARK: - Project

let project = Project(
    name: "TailnetDemo",
    options: .options(
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    settings: .settings(base: baseSettings, defaultSettings: .recommended),
    targets: [iosTarget, macTarget, iosUITestTarget, macUITestTarget, iosUnitTestTarget, macUnitTestTarget],
    schemes: [iosScheme, macScheme]
)
