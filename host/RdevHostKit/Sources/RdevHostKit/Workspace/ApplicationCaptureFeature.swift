/// Parked at the user's request, 2026-10-30. Retain the experiment and restoration code;
/// no environment opt-in may activate application capture in the product.
/// Findings and restart criteria: docs/experiments/2026-10-25-app-workspace/parking-report.md.
public enum ApplicationCaptureFeature {
    public static let enabled = false
}
