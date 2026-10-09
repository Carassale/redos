/// Cleans plans from the fast path and from models: no repeated launches, and "open browser + open URL"
/// becomes a single url.open in that browser.
public enum PlanSimplifier {
    private static let browsers: Set<String> = [
        "safari", "chrome", "google chrome", "firefox", "arc", "edge", "microsoft edge", "brave", "brave browser",
        "opera", "vivaldi", "orion", "zen",
    ]

    public static func simplify(_ steps: [ActionRequest]) -> [ActionRequest] {
        var result: [ActionRequest] = []
        var openedApps = Set<String>()
        for step in steps {
            if step.actionID == "app.open", let name = step.arguments["name"] {
                guard openedApps.insert(name.lowercased()).inserted else { continue }
            }
            if step.actionID == "url.open", let last = result.last, last.actionID == "app.open",
               let name = last.arguments["name"], opensURL(step, in: name) {
                let merged = step.arguments.merging(["app": name]) { _, new in new }
                result[result.count - 1] = ActionRequest("url.open", merged)
                continue
            }
            if step == result.last { continue }
            result.append(step)
        }
        return result
    }

    private static func opensURL(_ step: ActionRequest, in app: String) -> Bool {
        guard let target = step.arguments["app"] else { return browsers.contains(app.lowercased()) }
        return target.lowercased() == app.lowercased()
    }
}
