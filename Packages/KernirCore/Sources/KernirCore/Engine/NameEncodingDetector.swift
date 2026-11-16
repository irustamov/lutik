import Foundation

/// Picks one encoding for all of an archive's undeclared legacy names: every candidate decodes a sample of the
/// names, the one whose readings look most like real text wins. Results of `decode` are NFC.
enum NameEncodingDetector {
    /// At most this many distinct names are scored.
    static let sampleLimit = 4_096

    /// Fixed tie order; the UI language's candidate moves to the front.
    private static let candidates: [String.Encoding] = [
        .windowsCP1251, .cp866, .cp932, .gb18030, .big5, .cp949, .windowsCP1252, .cp437, .windowsCP1250, .koi8R,
    ]

    /// The first `sampleLimit` distinct names, in input order.
    static func sample(_ names: [[UInt8]]) -> [[UInt8]] {
        var seen = Set<[UInt8]>()
        var sample: [[UInt8]] = []
        for name in names where seen.insert(name).inserted {
            sample.append(name)
            if sample.count == sampleLimit { break }
        }
        return sample
    }

    /// `names`: raw bytes of undeclared names that are not all ASCII. Returns the single encoding for all of them.
    static func detect(_ names: [[UInt8]], preferredLanguages: [String] = Locale.preferredLanguages) -> String.Encoding {
        let sample = sample(names)
        if sample.allSatisfy({ String(bytes: $0, encoding: .utf8) != nil }) { return .utf8 }
        var best: (encoding: String.Encoding, score: Int)?
        for encoding in tieOrder(preferredLanguages) {
            guard let score = score(sample, as: encoding) else { continue }
            if score > best?.score ?? .min { best = (encoding, score) }
        }
        return best?.encoding ?? .cp437
    }

    /// `bytes` in `encoding`, or in CP437 (every byte maps) when they are not valid there. NFC (`EntryPath.nfc`).
    static func decode(_ bytes: [UInt8], as encoding: String.Encoding) -> String {
        let s = String(bytes: bytes, encoding: encoding) ?? String(bytes: bytes, encoding: .cp437)
            ?? String(decoding: bytes, as: UTF8.self)
        return EntryPath.nfc(s)
    }

    /// Sum of the per-name scores; nil when `encoding` cannot decode a name or yields a control, U+FFFD or a
    /// private-use scalar.
    private static func score(_ names: [[UInt8]], as encoding: String.Encoding) -> Int? {
        var total = 0
        for name in names {
            guard let s = String(bytes: name, encoding: encoding) else { return nil }
            let scalars = Array(s.unicodeScalars)
            if scalars.contains(where: isForbidden) { return nil }
            switch encoding {
            case .windowsCP1251, .cp866, .koi8R: total += singleByteScore(scalars, wordScore: cyrillicWordScore)
            case .windowsCP1252: total += singleByteScore(scalars, wordScore: windows1252WordScore)
            case .cp437, .windowsCP1250: total += singleByteScore(scalars) { latinWordScore($0) }
            case .cp932: total += japaneseScore(name, scalars)
            case .gb18030:
                total += doubleByteScore(name, gbRate) + 2 * scalars.count(where: commonHanzi.contains)
                    - 4 * squeezedCount(scalars)
            case .big5:
                total += doubleByteScore(name, big5Rate) + 2 * scalars.count(where: commonHanzi.contains)
                    - 4 * squeezedCount(scalars)
            case .cp949:
                total += doubleByteScore(name, cp949Rate) + 2 * scalars.count(where: commonHangul.contains)
                    - 4 * squeezedCount(scalars)
            default: return nil
            }
        }
        return total
    }

    private static func isForbidden(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return v < 0x20 || (0x7F...0x9F).contains(v) || v == 0xFFFD || (0xE000...0xF8FF).contains(v) || v >= 0xF0000
    }

    // MARK: Single-byte candidates

    /// Letters are scored a word (a run of letters) at a time; −4 per DOS pseudographic between words.
    private static func singleByteScore(_ scalars: [Unicode.Scalar], wordScore: ([Unicode.Scalar]) -> Int) -> Int {
        var score = 0
        var word: [Unicode.Scalar] = []
        for u in scalars {
            if u.isASCII ? isASCIILetter(u) : u.properties.isAlphabetic {
                word.append(u)
                continue
            }
            if !word.isEmpty { score += wordScore(word) }
            word.removeAll(keepingCapacity: true)
            if !u.isASCII, isPseudographic(u) { score -= 4 }
        }
        if !word.isEmpty { score += wordScore(word) }
        return score
    }

    /// Box drawing, blocks, shades, geometric shapes, non-ASCII math and currency symbols: what other code pages'
    /// letters turn into, and almost never part of a real name.
    private static func isPseudographic(_ u: Unicode.Scalar) -> Bool {
        if (0x2500...0x25FF).contains(u.value) { return true }
        let category = u.properties.generalCategory
        return category == .mathSymbol || category == .currencySymbol
    }

    /// +2 per Russian letter, −1 per other Cyrillic letter (Є ў Ї і Ђ …). The whole word scores −3 when it mixes
    /// ASCII letters with Cyrillic, has a Cyrillic uppercase letter right after a lowercase one that is not the
    /// start of a CamelCase part ("ВашеФото" is fine, "ИъЧЧ" is not), or starts with Ъ or Ь, which no Russian word
    /// does (CP866 "Счёт № 15" reads as "‘зсв ь 15" in CP1251): CP932, Latin and other Cyrillic bytes read as
    /// Cyrillic.
    private static func cyrillicWordScore(_ word: [Unicode.Scalar]) -> Int {
        if let first = word.first, [0x042A, 0x042C, 0x044A, 0x044C].contains(first.value) { return -3 }
        var score = 0, hasASCII = false, hasCyrillic = false, previousLower = false
        for (i, u) in word.enumerated() {
            let cyrillic = (0x0400...0x04FF).contains(u.value)
            if u.isASCII { hasASCII = true }
            if cyrillic { hasCyrillic = true }
            if cyrillic, previousLower, u.properties.isUppercase {
                guard i + 1 < word.count, (0x0400...0x04FF).contains(word[i + 1].value),
                      word[i + 1].properties.isLowercase
                else { return -3 }
            }
            previousLower = cyrillic && u.properties.isLowercase
            if (0x0410...0x044F).contains(u.value) || u.value == 0x0401 || u.value == 0x0451 {
                score += 2
            } else if cyrillic {
                score -= 1
            }
        }
        return hasASCII && hasCyrillic ? -3 : score
    }

    /// +2 per Latin letter U+00C0–U+024F that is not in `unscored`. The whole word scores −3 when its non-ASCII
    /// letters outnumber twice its ASCII letters plus one: Cyrillic read as Latin has no ASCII letters
    /// ("Ïðèâåò"), real words have some ("kůň", "Łódź").
    private static func latinWordScore(_ word: [Unicode.Scalar], unscored: Set<Unicode.Scalar> = []) -> Int {
        let ascii = word.count(where: \.isASCII)
        if word.count - ascii > 2 * ascii + 1 { return -3 }
        return 2 * word.count(where: { (0xC0...0x24F).contains($0.value) && !unscored.contains($0) })
    }

    /// CP1252's letters outside Latin-1 (bytes 0x8A–0x9F): rare in Western names, and where CP437's accented
    /// letters land ("Über" reads as "šber", "Ärger" as "Žrger"). Czech and Slovak names have CP1250 for them.
    private static let windows1252Extras: Set<Unicode.Scalar> = ["Š", "š", "Œ", "œ", "Ž", "ž", "Ÿ"]

    /// `latinWordScore` with the CP1252 extras unscored, plus +4 per French Œ/œ before an ASCII vowel ("cœur",
    /// "Œuvre", "œil"): the ligature is two letters, o and e. The same bytes are Ś/ś in CP1250, which Polish never
    /// writes before a vowel (it writes "si"), and î/£ in CP437, where î comes before a consonant ("île",
    /// "maître"); so neither competitor earns the bonus. Œ/œ before a consonant ("fœtus") still scores 0.
    private static func windows1252WordScore(_ word: [Unicode.Scalar]) -> Int {
        let score = latinWordScore(word, unscored: windows1252Extras)
        guard score >= 0, word.count > 1 else { return score }
        let ligatures = (0..<word.count - 1).count {
            (word[$0] == "Œ" || word[$0] == "œ") && "aeiouAEIOU".unicodeScalars.contains(word[$0 + 1])
        }
        return score + 4 * ligatures
    }

    // MARK: Double-byte candidates

    /// Full-width kana +3, JIS level 1 kanji +2, level 2 0, IBM/NEC extensions −1, half-width katakana −2
    /// (most Russian and Latin bytes land there), and −4 per kana or kanji squeezed between two ASCII letters
    /// (CP437 "Größe" reads as "Gr" + kanji + "e") or per lone kanji, with no kana or kanji on either side,
    /// next to an ASCII letter (CP437 "Ångström" reads as kanji + "str" + kanji, "Ärger" as kanji + "ger").
    private static func japaneseScore(_ bytes: [UInt8], _ scalars: [Unicode.Scalar]) -> Int {
        let isLead: (UInt8) -> Bool = { (0x81...0x9F).contains($0) || (0xE0...0xFC).contains($0) }
        var score = doubleByteScore(bytes, isLead: isLead) { lead, _ in
            switch lead {
            case 0x88...0x98: 2
            case 0xED...0xFC: -1
            default: 0
            }
        }
        for (i, u) in scalars.enumerated() {
            let v = u.value
            if (0xFF61...0xFF9F).contains(v) { score -= 2 }
            let kana = isKana(u)
            if kana { score += 3 }
            guard kana || isKanji(u) else { continue }
            let left = i > 0 ? scalars[i - 1] : nil, right = i + 1 < scalars.count ? scalars[i + 1] : nil
            let squeezed = left.map(isASCIILetter) == true && right.map(isASCIILetter) == true
            let lone = !kana && ![left, right].contains { $0.map { isKana($0) || isKanji($0) } == true }
                && [left, right].contains { $0.map(isASCIILetter) == true }
            if squeezed || lone { score -= 4 }
        }
        return score
    }

    private static func isKana(_ u: Unicode.Scalar) -> Bool { (0x3041...0x30FF).contains(u.value) }

    private static func isKanji(_ u: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value)
    }

    /// Non-ASCII characters squeezed between two ASCII letters (CP437 "Señor" reads as "Se" + hanzi + "r" in
    /// Big5): −4 each for GB18030, Big5 and CP949, like CP932's rule.
    private static func squeezedCount(_ scalars: [Unicode.Scalar]) -> Int {
        guard scalars.count > 2 else { return 0 }
        return (1..<scalars.count - 1).count {
            !scalars[$0].isASCII && isASCIILetter(scalars[$0 - 1]) && isASCIILetter(scalars[$0 + 1])
        }
    }

    /// Sum of `rate(lead, trail)` over the double-byte characters (`isLead` starts one); GB18030 four-byte
    /// sequences score −1.
    private static func doubleByteScore(_ bytes: [UInt8], isLead: (UInt8) -> Bool = { $0 >= 0x81 },
                                        _ rate: (UInt8, UInt8) -> Int) -> Int {
        var score = 0, i = 0
        while i < bytes.count {
            guard isLead(bytes[i]), i + 1 < bytes.count else { i += 1; continue }
            if (0x30...0x39).contains(bytes[i + 1]) {
                score -= 1
                i += 4
            } else {
                score += rate(bytes[i], bytes[i + 1])
                i += 2
            }
        }
        return score
    }

    /// GB2312 level 1 hanzi +3, level 2 +1, full-width punctuation −1, GB2312 kana, Greek, Cyrillic, pinyin and
    /// box-drawing rows −3 (where Big5 symbol bytes land), GBK extension −1.
    private static func gbRate(_ lead: UInt8, _ trail: UInt8) -> Int {
        guard trail >= 0xA1 else { return -1 }
        switch lead {
        case 0xB0...0xD7: return 3
        case 0xD8...0xF7: return 1
        case 0xA4...0xA9: return -3
        default: return -1
        }
    }

    /// Frequent hanzi +3, less frequent +1, symbols and extensions −1.
    private static func big5Rate(_ lead: UInt8, _ trail: UInt8) -> Int {
        switch lead {
        case 0xA4...0xC6: 3
        case 0xC9...0xF9: 1
        default: -1
        }
    }

    /// KS X 1001 Hangul +3, Hanja 0, extension Hangul and symbols −1.
    private static func cp949Rate(_ lead: UInt8, _ trail: UInt8) -> Int {
        guard trail >= 0xA1 else { return -1 }
        switch lead {
        case 0xB0...0xC8: return 3
        case 0xCA...0xFD: return 0
        default: return -1
        }
    }

    private static func isASCIILetter(_ u: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value)
    }

    // MARK: Tie order

    private static func tieOrder(_ preferredLanguages: [String]) -> [String.Encoding] {
        guard let preferred = preferredLanguages.lazy.compactMap(encoding(forLanguage:)).first else { return candidates }
        return [preferred] + candidates.filter { $0 != preferred }
    }

    /// The legacy Windows encoding of a UI language: Cyrillic scripts CP1251, Central European CP1250, other
    /// Latin scripts CP1252. Nil for languages without one here (Greek, Arabic, …).
    private static func encoding(forLanguage identifier: String) -> String.Encoding? {
        let language = Locale.Language(identifier: identifier)
        switch (language.languageCode?.identifier, language.script?.identifier) {
        case ("ja", _): return .cp932
        case ("ko", _): return .cp949
        case ("zh", "Hant"): return .big5
        case ("zh", _): return .gb18030
        case ("cs", _), ("pl", _), ("hu", _), ("sk", _): return .windowsCP1250
        case (_, "Cyrl"): return .windowsCP1251
        case (_, "Latn"): return .windowsCP1252
        default: return nil
        }
    }

    // MARK: Frequent characters

    /// About 500 of the most frequent hanzi, simplified and traditional: real Chinese names are mostly made of
    /// them, Korean or Cyrillic bytes read as hanzi rarely are. +2 each.
    private static let commonHanzi = Set((
        "的一是不了人我在有他这中大来上个国到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天"
        + "而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些"
        + "与高意进把法此实回二理美点月明其种声全工己话儿者向情部正名定女问力机给等几很业最间新什打便位因重被走电四第门相"
        + "次东政海口使教西再平真听世气信北少关并内加化由却代军产入先山五太水万市眼体别处总才场师书比住员九笑性通目华报立"
        + "马命张活难神数件安表原车白应路期叫死常提感金何更反合放做系计或司利受光王果亲界及今京务制解各任至清物台象记边共"
        + "风战干接它许八特觉望直服毛林题建南度统色字请交爱让认算论百吃义科怎元社术结六功指思非流每青管夫连远资队跟带花快"
        + "条院变联言权往展该领传近留红治决周保达办运武半候七必城父强步完革深区即求品士转量空甚众技轻程告江语英基派满式李"
        + "息写呢识极令黄德收脸钱党倒未持取设始版双历越史商千片容研像找友孩站广改议形委早房音火际则首单据导影失拿网香似斯"
        + "专石若兵弟谁校读志飞观争究包组造落视济喜离虽坏兴切妈消录档案图照项稿终课格划纪申简"
        + "這來個國說們為時會著過學對裡後麼發當無開見經頭從動兩長樣現將與實點種聲話兒問機給幾業間電門東聽氣關內軍產萬體別"
        + "處總場師書員華報馬張難數車應親務記邊風戰許覺題統請愛讓認論義術結連遠資隊帶條變聯權該領傳紅決達辦運強區轉眾輕語"
        + "滿寫識極黃臉錢黨設雙歷廣議際則單據導網專誰讀飛觀爭組視濟離雖壞興媽錄檔圖項終課劃紀簡"
    ).unicodeScalars)

    /// About 300 of the most frequent Hangul syllables. +2 each.
    private static let commonHangul = Set((
        "이의다는에하고서기자사지리가로을를은한인대정도수일시어나전아구해스상부보들요주제소성계과장화경신여국개원문공"
        + "모연생위동내우무만비라미학오회년거업진세조분실마관니안방중데와작금했것력후결통용적할있없그저런면단발선명행식품"
        + "출물차영교감반날체표권파트크프터드레디바브즈컴퓨포토록류목양견본활입검향래송험법처율례려각강건격근급남녀능달당"
        + "덕독람량령료루률망백번별병복봉북불빛산새색석설속손순술승심씨액약언역열예옥완왕외운월유육음익임잔잘재절점접종"
        + "좌준증직집참창책천철청초총최추축충측층치칙친타태택투특판편평포풍피필함합항현형호혼홍확환황효휴흥희힘게께네메베"
        + "케테페헤그느르므스으츠흐간난란찬칸탄"
    ).unicodeScalars)
}
