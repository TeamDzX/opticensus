import Foundation

/// The one place the product name lives until it is settled.
public enum Product {
    public static let name = "OptiCensus"
    public static let command = "opticensus"
    public static let version = "0.1.1"
    /// Days an allowed item may go unseen before it is reported as gone.
    public static let goneAfterDays = 30
}
