import RedOSCore

public enum SystemActions {
    public static var all: [any Action] {
        [
            OpenAppAction(), QuitAppAction(), OpenURLAction(), TypeTextAction(), ScrollAction(), MoveMouseAction(),
            ClickAction(), PressElementAction(), FillFieldAction(), ReadScreenAction(), RunShellAction(),
        ]
    }
}
