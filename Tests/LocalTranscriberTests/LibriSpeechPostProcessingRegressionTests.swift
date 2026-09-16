import Foundation
import XCTest
@testable import LocalTranscriber

final class LibriSpeechPostProcessingRegressionTests: XCTestCase {
    private struct Fixture {
        let id: String
        let reference: String
        let raw: String
    }

    func testQwenDoesNotDamageFluentLibriSpeechTranscripts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WORDMATE_RUN_LIBRISPEECH_REGRESSIONS"] == "1" else {
            throw XCTSkip("Run explicitly with WORDMATE_RUN_LIBRISPEECH_REGRESSIONS=1")
        }

        let processor = TranscriptPostProcessor()
        try await processor.prepare(.qwen3_0_6b)

        var aggregateRawErrors = 0
        var aggregatePolishedErrors = 0
        var worsenedIDs: [String] = []
        let clock = ContinuousClock()
        let benchmarkStarted = clock.now

        for fixture in Self.fixtures {
            let started = clock.now
            let polished = try await processor.polish(
                fixture.raw,
                using: .qwen3_0_6b
            )
            let elapsed = regressionSeconds(started.duration(to: clock.now))
            let rawErrors = Self.wordErrorCount(
                fixture.raw,
                fixture.reference
            )
            let polishedErrors = Self.wordErrorCount(
                polished,
                fixture.reference
            )
            aggregateRawErrors += rawErrors
            aggregatePolishedErrors += polishedErrors
            if polishedErrors > rawErrors {
                worsenedIDs.append(fixture.id)
            }

            print("LIBRISPEECH_REGRESSION_BEGIN")
            print("ID=\(fixture.id)")
            print("RAW_ERRORS=\(rawErrors)")
            print("POLISHED_ERRORS=\(polishedErrors)")
            print("POST_PROCESS_SECONDS=\(format(elapsed))")
            print("POLISHED_TRANSCRIPT_BEGIN")
            print(polished)
            print("POLISHED_TRANSCRIPT_END")
            print("LIBRISPEECH_REGRESSION_END")
        }

        let totalDuration = regressionSeconds(
            benchmarkStarted.duration(to: clock.now)
        )
        print("LIBRISPEECH_REGRESSION_CASES=\(Self.fixtures.count)")
        print("LIBRISPEECH_REGRESSION_RAW_ERRORS=\(aggregateRawErrors)")
        print("LIBRISPEECH_REGRESSION_POLISHED_ERRORS=\(aggregatePolishedErrors)")
        print("LIBRISPEECH_REGRESSION_WORSENED_IDS=\(worsenedIDs.joined(separator: ","))")
        print("LIBRISPEECH_REGRESSION_TOTAL_SECONDS=\(format(totalDuration))")

        XCTAssertEqual(
            aggregateRawErrors,
            8,
            "The captured raw-transcript baseline unexpectedly changed"
        )
        XCTAssertEqual(
            worsenedIDs,
            [],
            "Qwen removed valid content from: \(worsenedIDs.joined(separator: ", "))"
        )
        XCTAssertLessThanOrEqual(
            aggregatePolishedErrors,
            aggregateRawErrors,
            "Qwen must not increase aggregate errors on fluent speech"
        )
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func wordErrorCount(_ actual: String, _ expected: String) -> Int {
        editDistance(normalizedWords(actual), normalizedWords(expected))
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
    }

    private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsWord) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = lhsIndex + 1
            for (rhsIndex, rhsWord) in rhs.enumerated() {
                current[rhsIndex + 1] = min(
                    previous[rhsIndex + 1] + 1,
                    current[rhsIndex] + 1,
                    previous[rhsIndex] + (lhsWord == rhsWord ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            id: "3005-163390-0020",
            reference: "ALL I SAY IS KINGS IS KINGS AND YOU GOT TO MAKE ALLOWANCES",
            raw: "All I say is, kings is kings, and you got to make allowances."
        ),
        Fixture(
            id: "3575-170457-0047",
            reference: "TABBY HAD LIVED WITH THEM FOR TEN OR TWELVE YEARS AND WAS AS CHARLOTTE EXPRESSED IT ONE OF THE FAMILY",
            raw: "Tabby had lived with them for ten or twelve years, and was, as Charlotte expressed it, one of the family"
        ),
        Fixture(
            id: "8463-294828-0006",
            reference: "FROM RUBBING SHOULDERS WITH SCIENTISTS IN OUR LITTLE UNIVERSE BY THE BOTANICAL GARDENS THE BOY HAD COME TO KNOW A THING OR TWO",
            raw: "From rubbing shoulders with scientists in our little universe by the botanical gardens, the boy had come to know a thing or two."
        ),
        Fixture(
            id: "4507-16021-0001",
            reference: "IT ENGENDERS A WHOLE WORLD LA PEGRE FOR WHICH READ THEFT AND A HELL LA PEGRENNE FOR WHICH READ HUNGER",
            raw: "It engenders a whole world la pègre, for which read theft, and a hell la pegrenne, for which red hunger."
        ),
        Fixture(
            id: "6829-68769-0036",
            reference: "THEY LEFT HIM THEN FOR THE JAILER ARRIVED TO UNLOCK THE DOOR AND ESCORT THEM TO THE OFFICE",
            raw: "They left him then, for the jailer arrived to unlock the door and escort them to the office."
        ),
        Fixture(
            id: "6930-76324-0021",
            reference: "SURFACE DUST AT LEAST HAD BEEN REMOVED AND THE FINE OLD FURNITURE GAVE A HINT OF ITS REAL ELEGANCE AND POLISH",
            raw: "Surface dust, at least, had been removed, and the fine old furniture gave a hint of its real elegance and polish."
        ),
        Fixture(
            id: "1320-122617-0033",
            reference: "IF HOWEVER THEY TAKE YOUR SCALP AS I TRUST AND BELIEVE THEY WILL NOT DEPEND ON IT UNCAS AND I WILL NOT FORGET THE DEED BUT REVENGE IT AS BECOMES TRUE WARRIORS AND TRUSTY FRIENDS",
            raw: "If, however, they take your scalp, as I trust and believe they will not, depend on it, Uncas and I will not forget the deed, but revenge it as becomes true warriors and trusty friends."
        ),
        Fixture(
            id: "2961-960-0014",
            reference: "THE IDEAS ALSO REMAIN BUT THEY HAVE BECOME TYPES IN NATURE FORMS OF MEN ANIMALS BIRDS FISHES",
            raw: "The ideas also remain, but they have become types in nature, forms of men, animals, birds, fishes"
        ),
        Fixture(
            id: "5639-40744-0021",
            reference: "SHE MEANWHILE PASSED HER LIFE WITH HER PARENTS IN THE STRICTEST RETIREMENT NEVER LETTING HERSELF BE SEEN BUT SHUNNING EVERY EYE LEST IT SHOULD READ HER MISFORTUNE IN HER FACE",
            raw: "She meanwhile passed her life with her parents in the strictest retirement, never letting herself be seen, but shunning every eye lest it should read her misfortune in her face."
        ),
        Fixture(
            id: "7021-79740-0011",
            reference: "SO SAYING SHE LED THE WAY ON TIPTOE FOLLOWED BY THE CHILDREN OUT OF THE ROOM AND ROUND BY A CIRCUITOUS ROUTE TO THE PIAZZA THERE",
            raw: "So saying, she led the way on tiptoe, followed by the children out of the room, and round by a circuitous route to the piazza. There"
        ),
        Fixture(
            id: "8224-274381-0016",
            reference: "VALOR INDEED WAS VERY GENERALLY DIFFUSED OVER THE ONE PARTY AS WELL AS THE OTHER DURING THIS PERIOD DISCIPLINE ALSO WAS ATTAINED BY THE FORCES OF THE PARLIAMENT BUT THE PERFECTION OF THE MILITARY ART IN CONCERTING THE GENERAL PLANS OF ACTION AND THE OPERATIONS OF THE FIELD SEEMS STILL ON BOTH SIDES TO HAVE BEEN IN A GREAT MEASURE WANTING",
            raw: "Valor, indeed, was very generally diffused over the one party as well as the other. During this period, discipline also was attained by the forces of the parliament, but the perfection of the military art in concerting the general plans of action and the operations of the field seems still on both sides to have been in a great measure wanting."
        ),
        Fixture(
            id: "5105-28240-0009",
            reference: "SLIGHTLY CHANGING HER COURSE SHE FIRST STRUCK HER MAINSAIL AND IN ORDER TO FACILITATE THE MOVEMENTS OF HER HELMSMAN SOON CARRIED NOTHING BUT HER TWO TOPSAILS BRIGANTINE AND JIB",
            raw: "Slightly changing her course, she first struck her mainsail, and in order to facilitate the movements of her helmsmen, soon carried nothing but her two topsails, brigantine and jib."
        ),
        Fixture(
            id: "2961-961-0004",
            reference: "LISTEN THEN SOCRATES TO A TALE OF SOLON'S WHO BEING THE FRIEND OF DROPIDAS MY GREAT GRANDFATHER TOLD IT TO MY GRANDFATHER CRITIAS AND HE TOLD ME",
            raw: "Listen then, Socrates, to a tale of Solens, who, being the friend of Dropidas, my great grandfather, told it to my grandfather Critias, and he told me."
        ),
        Fixture(
            id: "1580-141083-0020",
            reference: "THEN HE APPROACHED IT AND STANDING ON TIPTOE WITH HIS NECK CRANED HE LOOKED INTO THE ROOM",
            raw: "Then he approached it, and standing on tiptoe with his neck craned, he looked into the room."
        ),
        Fixture(
            id: "1580-141084-0023",
            reference: "IN A FEW HOURS THE EXAMINATION WOULD COMMENCE AND HE WAS STILL IN THE DILEMMA BETWEEN MAKING THE FACTS PUBLIC AND ALLOWING THE CULPRIT TO COMPETE FOR THE VALUABLE SCHOLARSHIP",
            raw: "In a few hours the examination would commence, and he was still in the dilemma between making the facts public and allowing the culprit to compete for the valuable scholarship."
        ),
        Fixture(
            id: "237-134500-0000",
            reference: "FRANK READ ENGLISH SLOWLY AND THE MORE HE READ ABOUT THIS DIVORCE CASE THE ANGRIER HE GREW",
            raw: "Frank read English slowly, and the more he read about this divorce case, the angrier he grew."
        ),
        Fixture(
            id: "260-123286-0009",
            reference: "I TAKE THIS AS MY ANSWER AND I LEAVE THE PROFESSOR TO BITE HIS LIPS WITH IMPATIENCE",
            raw: "I take this as my answer, and I leave the professor, to bite his lips with impatience."
        ),
        Fixture(
            id: "61-70970-0036",
            reference: "ROBIN FITZOOTH SAW THAT HIS DOUBTS OF WARRENTON HAD BEEN UNFAIR AND HE BECAME ASHAMED OF HIMSELF FOR HARBORING THEM",
            raw: "Robin Fitzooth saw that his doubts of Warranton had been unfair, and he became ashamed of himself for harbouring them."
        ),
        Fixture(
            id: "2830-3980-0037",
            reference: "SO MUCH FOR THE TITLE OF THE EPISTLE NOW FOLLOWS THE GREETING OF THE APOSTLE VERSE THREE",
            raw: "So much for the title of the Epistle now follows the greeting of the Apostle. Verse three."
        ),
        Fixture(
            id: "5105-28240-0021",
            reference: "BEFORE STARTING IT WAS INDISPENSABLE THAT THE ENGINE OF THE DOBRYNA SHOULD BE REPAIRED TO SAIL UNDER CANVAS ONLY WOULD IN CONTRARY WINDS AND ROUGH SEAS BE BOTH TEDIOUS AND DIFFICULT",
            raw: "Before starting, it was indispensable that the engine of the Dobrina should be repaired. To sail under canvas only would, in contrary winds and rough seas, be both tedious and difficult."
        ),
    ]
}

private func regressionSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
