import Foundation
import VideoContextCore
import WhisperKit

/// Adapts the SDK's local tokenizer factory without its network fallback.
/// Video Context requests segment timestamps; word-level alignment is not enabled.
struct OfflineWhisperTokenizer: WhisperTokenizer {
    let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(tokenizer: TokenizerWrapper) throws {
        func token(_ value: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(value) else {
                throw LocalProviderError.configuration("The local Whisper tokenizer is incomplete. Download the speech model again in Settings.")
            }
            return id
        }
        self.tokenizer = tokenizer
        specialTokens = try SpecialTokens(endToken: token("<|endoftext|>"), englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"),
            specialTokenBegin: token("<|endoftext|>"), startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: token("<|0.00|>"),
            transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"),
            whitespaceToken: tokenizer.encode(text: " ", addSpecialTokens: false).first ?? 220)
        allLanguageTokens = Set((specialTokens.startOfTranscriptToken + 1..<specialTokens.translateToken).filter {
            guard let value = tokenizer.convertIdToToken($0), value.hasPrefix("<|"), value.hasSuffix("|>") else { return false }
            let code = value.dropFirst(2).dropLast(2)
            return (2...3).contains(code.count) && code.allSatisfy(\.isLetter)
        })
    }
    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = [], groups: [[Int]] = [], pending: [Int] = []
        for id in tokenIds {
            pending.append(id)
            let value = decode(tokens: pending)
            if value.contains("\u{fffd}") { continue }
            if !value.hasPrefix(" "), id < specialTokens.specialTokenBegin, !groups.isEmpty {
                words[words.count - 1] += value; groups[groups.count - 1] += pending
            } else { words.append(value); groups.append(pending) }
            pending = []
        }
        if !pending.isEmpty { words.append(decode(tokens: pending)); groups.append(pending) }
        return (words, groups)
    }
}
