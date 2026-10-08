import RedOSCore

public enum SystemActions {
    public static var all: [any Action] {
        [OpenAppAction(), QuitAppAction(), TypeTextAction(), ScrollAction(), MoveMouseAction(), ClickAction()]
    }
}
