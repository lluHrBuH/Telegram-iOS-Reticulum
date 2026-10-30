import Foundation
import TelegramUIPreferences

/// The Reticulum `config` file the Rust stack reads at start, written from `ReticulumSettings`.
/// Only TCP client interfaces live in the file: radios are host-fed and registered at run time.
enum ReticulumConfigFile {
    static func text(settings: ReticulumSettings) -> String {
        var lines: [String] = []
        lines.append("[reticulum]")
        // A phone relays nothing: it is a leaf, and a transport node on a flaky link hurts the mesh.
        lines.append("enable_transport = false")
        lines.append("share_instance = false")
        lines.append("panic_on_interface_errors = false")
        lines.append("")
        lines.append("[logging]")
        lines.append("loglevel = \(max(0, min(7, settings.logLevel)))")
        lines.append("")
        lines.append("[interfaces]")
        var usedNames = Set<String>()
        for node in settings.tcpNodes {
            let host = node.host.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty {
                continue
            }
            var name = ReticulumConfigFile.interfaceName(for: node)
            var suffix = 2
            while usedNames.contains(name) {
                name = ReticulumConfigFile.interfaceName(for: node) + " \(suffix)"
                suffix += 1
            }
            usedNames.insert(name)
            lines.append("  [[\(name)]]")
            lines.append("    type = TCPClientInterface")
            lines.append("    enabled = \(node.enabled ? "yes" : "no")")
            lines.append("    target_host = \(host)")
            lines.append("    target_port = \(node.port)")
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The interface name the stack reports for a node, as `tgrns_interface_at` names it.
    static func interfaceName(for node: ReticulumSettings.TCPNode) -> String {
        let raw = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? "\(node.host):\(node.port)" : raw
        // Section names end at the closing brackets; keep them out of the name.
        return base.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }
}
