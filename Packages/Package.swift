// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeFinancesKit",
    defaultLocalization: "it",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "HomeFinancesKit",
            targets: [
                "Core",
                "Persistence",
                "AppSecurity",
                "DesignSystem",
                "LockFeature",
                "HomeFeature",
                "HistoryFeature",
                "OperationEditorFeature",
                "SettingsFeature",
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Modelli di dominio e regole: nessuna dipendenza.
        .target(name: "Core", path: "Core"),

        // Unico modulo che conosce GRDB e il percorso del database (§ 5.6).
        .target(
            name: "Persistence",
            dependencies: [
                "Core",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Persistence"
        ),

        // "Security" collide con il framework di sistema: il modulo si chiama AppSecurity.
        .target(name: "AppSecurity", dependencies: ["Core"], path: "Security"),

        .target(name: "DesignSystem", dependencies: ["Core"], path: "DesignSystem"),

        // Le feature dipendono da Core, DesignSystem e dai protocolli dei repository, mai da GRDB.
        .target(name: "LockFeature", dependencies: ["Core", "DesignSystem", "AppSecurity"], path: "Features/Lock"),
        .target(name: "HomeFeature", dependencies: ["Core", "DesignSystem"], path: "Features/Home"),
        .target(name: "HistoryFeature", dependencies: ["Core", "DesignSystem"], path: "Features/History"),
        .target(name: "OperationEditorFeature", dependencies: ["Core", "DesignSystem"], path: "Features/OperationEditor"),
        .target(name: "SettingsFeature", dependencies: ["Core", "DesignSystem", "AppSecurity"], path: "Features/Settings"),

        .testTarget(name: "CoreTests", dependencies: ["Core"], path: "Tests/CoreTests"),
        .testTarget(name: "PersistenceTests", dependencies: ["Core", "Persistence"], path: "Tests/PersistenceTests"),
        .testTarget(name: "AppSecurityTests", dependencies: ["AppSecurity"], path: "Tests/AppSecurityTests"),
        .testTarget(
            name: "OperationEditorFeatureTests",
            dependencies: ["Core", "OperationEditorFeature", "Persistence"],
            path: "Tests/OperationEditorFeatureTests"
        ),
    ]
)
