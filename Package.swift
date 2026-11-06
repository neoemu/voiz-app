// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Voiz",
    platforms: [
        // Alinhado ao MACOSX_DEPLOYMENT_TARGET = 26.0 do voiz.xcodeproj: sem isso o
        // `swift build` compila com um mínimo diferente do app e some com APIs do macOS 26.
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "Voiz",
            targets: ["Voiz"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Voiz",
            dependencies: ["WhisperKit", "FluidAudio", "Sparkle"],
            path: "voiz",
            // Espelho das flags de concorrência do alvo `voiz` no pbxproj. Sem isso o
            // `swift build` não é o mesmo compilador do Xcode e quebra sozinho:
            //   SWIFT_VERSION = 5.0                  -> .swiftLanguageMode(.v5)
            //   SWIFT_DEFAULT_ACTOR_ISOLATION        -> .defaultIsolation(MainActor.self)
            //   SWIFT_APPROACHABLE_CONCURRENCY = YES -> as 5 upcoming features abaixo
            //     (inclui InferIsolatedConformances, que o Xcode 26.6 liga junto — achado
            //      MENOR do review da T1.1)
            //   SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY -> MemberImportVisibility
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        )
    ]
)
