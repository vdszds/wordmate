import XCTest
@testable import LocalTranscriber

final class SpokenNumberFormatterTests: XCTestCase {
    private func check(_ input: String, _ expected: String, line: UInt = #line) {
        XCTAssertEqual(SpokenNumberFormatter.format(input), expected, line: line)
    }

    func testCardinalsAtTenAndAboveBecomeNumerals() {
        check("I told him ten times that we will be away.", "I told him 10 times that we will be away.")
        check("Almost twenty four hours have passed.", "Almost 24 hours have passed.")
        check("an archipelago of four hundred and six islands", "an archipelago of 406 islands")
        check("the four thousand franc bonus", "the 4,000 franc bonus")
        check("sixty thousand Swiss francs", "60,000 Swiss francs")
        check("twenty-four hours", "24 hours")
    }

    func testSmallNumbersStayAsWords() {
        check("one of the more obscure words", "one of the more obscure words")
        check("we can only keep the car for one week", "we can only keep the car for one week")
        check("over six million people", "over six million people")
        check("the first Monday", "the first Monday")
        check("a second later", "a second later")
        check("zero", "zero")
    }

    func testOrdinals() {
        check("back on the twenty eighth", "back on the 28th")
        check("the sixteenth, seventeenth or eighteenth of September", "the 16th, 17th or 18th of September")
        check("from September fifth until the twenty sixth", "from September 5th until the 26th")
        check("the fifth of September", "the 5th of September")
        check("the twenty first and the twenty second", "the 21st and the 22nd")
    }

    func testYears() {
        check("ever since nineteen sixty six", "ever since 1966")
        check("in twenty nineteen we moved", "in 2019 we moved")
        check("by twenty twenty five", "by 2025")
        check("in nineteen hundred", "in 1900")
        check("a nineteen fourteen translation", "a 1914 translation")
        check("back in eighteen twelve", "back in 1812")
    }

    func testPercentDecimalsAndDigitCodes() {
        check("there is zero percent lease", "there is 0% lease")
        check("roughly forty percent live there", "roughly 40% live there")
        check("sections one point ten point thirty two and one point ten point thirty three", "sections 1.10.32 and 1.10.33")
        check("version one point five", "version 1.5")
        check("the one point seven billion model sits in between", "the 1.7 billion model sits in between")
        check("two point five million dollars", "2.5 million dollars")
        check("one point zero five percent", "1.05%")
        check("three point one four one five", "3.1415")
        check("call zero six one eight five five three zero two one", "call 0618553021")
        check("zero four three three four four seven three fifty", "04334473 50")
    }

    func testPunctuationAndCasingAreKept() {
        check("Twenty four, he said.", "24, he said.")
        check("(forty percent)", "(40%)")
        check("\"Twenty eighth.\"", "\"28th.\"")
        check("Number words like a hundred stay: a hundred.", "Number words like a hundred stay: a hundred.")
    }

    func testMixedTextIsOtherwiseUntouched() {
        let text = "Lorem Ipsum has been the industry's standard dummy text ever since 1966. When designers at Letraset took a 1914 translation, it survived 2,000 years."
        check(text, text)
    }
}
