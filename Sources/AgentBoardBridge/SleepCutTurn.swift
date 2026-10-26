/// SPEC §8: a model request cut off by system sleep ends the turn on `StopFailure` with this exact
/// text. Its `error` field is `server_error`, which other failures share, so the text is the signal.
public enum SleepCutTurn {
    public static let message =
        "API Error: Your computer went to sleep mid-response. The response above may be incomplete."
    public static let continuation =
        "Your last turn was cut off by system sleep. Continue the task from where you stopped; "
        + "if your work is committed, file your report."
}
