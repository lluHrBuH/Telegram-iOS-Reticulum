load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# The app's side of the Reticulum backend: the Rust stack's lifecycle (one transport per
# process), the identity files, the mesh transport the local server sends through, and the
# Bluetooth hosts for RNode and RTNode radios. TelegramCore owns the protocols this implements;
# nothing here is shared with Telegram-Mac.
swift_library(
    name = "ReticulumEngine",
    module_name = "ReticulumEngine",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//third-party/reticulum:ReticulumFFI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
