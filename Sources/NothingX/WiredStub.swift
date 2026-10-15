// STUB — drop at merge. The wired-mode detection workstream provides the real `isWired`
// (`usbPresent && connection != .connected`, fed by an IOKit monitor). Delete this file when merging it.
extension HeadphoneModel {
    var isWired: Bool { false }
}
