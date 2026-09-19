import Foundation

/// A whole openGym profile, in process, so the Gym screens can be opened,
/// reviewed and screenshotted on a machine that has never seen the orin.
///
/// The SHAPE is real - the three routines are Arya's own split, because a
/// fixture whose structure differs from production is a fixture that proves
/// nothing about the screens. Every NUMBER is invented: the weights, the reps,
/// the bodyweight series and the two past sessions are made up for this file
/// and are not Arya's training log. Same rule as `DemoFixtures` (see
/// PRIVACY.md), and it matters more here, because this is health-class data.
///
/// Every exercise is a CUSTOM one. That is not laziness: openGym's 1324
/// built-in names live in the container's dataset and no ATARU endpoint
/// publishes them, so a fixture built on catalogue ids would render as "0043"
/// everywhere Demo is used. Custom exercises carry their names in the document
/// itself, which is exactly what makes Demo renderable offline.
enum GymFixtures {

    static func document() -> GymDocument {
        GymDocument(revision: 7, state: GymState(raw: state()))
    }

    // MARK: - The split

    /// name, sets, reps, weight (kg). Structure from Arya's split; numbers
    /// invented.
    private static let dayA: [(String, Int, Int, Double)] = [
        ("Leg Extension (Machine)", 2, 12, 45),
        ("Zercher Squat", 2, 8, 60),
        ("Bench Press (Dumbbell)", 2, 10, 24),
        ("Incline Bench Press (Dumbbell)", 2, 10, 20),
        ("Tricep Pushdown (Cable)", 2, 12, 25),
        ("Lateral Raise (Cable)", 1, 15, 7.5),
        ("Y-Raise (Cable)", 1, 15, 5),
        ("Shoulder Press (Plate Loaded)", 1, 10, 40)
    ]

    private static let dayB: [(String, Int, Int, Double)] = [
        ("Lat Pulldown (Cable)", 2, 10, 55),
        ("SA Lat Row (Cable)", 2, 10, 30),
        ("Kelso Shrug (Dumbbell)", 2, 12, 22),
        ("Seated Bicep Curl (Dumbbell)", 2, 10, 14),
        ("Reverse Curl (EZ Bar)", 2, 12, 20),
        ("Seated Leg Curl (Machine)", 2, 12, 40),
        ("Back Extension", 2, 12, 0)
    ]

    private static let dayC: [(String, Int, Int, Double)] = [
        ("Decline Crunch", 2, 15, 0),
        ("Side Bend (Back Extension)", 2, 15, 10),
        ("Wrist Curl (Dumbbell)", 2, 15, 8),
        ("Forearm Extensor (Dumbbell)", 2, 15, 6),
        ("Tib Raise", 2, 20, 0),
        ("Calf Press (Machine)", 2, 15, 70),
        ("Rear Delt Fly (Cable)", 2, 15, 9)
    ]

    /// Deterministic, and openGym-shaped: a custom id is "c" plus a uid. Fixed
    /// rather than generated so a relaunch does not invent a second copy of
    /// the same exercise.
    private static func exerciseID(_ routine: String, _ index: Int) -> String {
        "cdemo\(routine)\(String(format: "%02d", index))"
    }

    private static func routine(id: String, name: String, letter: String,
                                exercises: [(String, Int, Int, Double)],
                                tag: String) -> [String: JSONValue] {
        let configs = exercises.enumerated().map { index, exercise -> JSONValue in
            var config: [String: JSONValue] = [
                "id": .string(exerciseID(tag, index)),
                "sets": .int(exercise.1),
                "reps": .int(exercise.2),
                "weight": .number(exercise.3)
            ]
            // Bodyweight movements carry the flag, exactly as a profile does
            // when it differs from the catalogue's default.
            if exercise.3 == 0 { config["bodyweight"] = .bool(true) }
            return .object(config)
        }
        return ["id": .string(id), "name": .string(name), "emoji": .string(letter),
                "ex": .array(configs)]
    }

    private static func customExercises() -> [JSONValue] {
        var all: [JSONValue] = []
        for (tag, list) in [("a", dayA), ("b", dayB), ("c", dayC)] {
            for (index, exercise) in list.enumerated() {
                all.append(.object([
                    "id": .string(exerciseID(tag, index)),
                    "n": .string(exercise.0),
                    "bp": .string(""), "eq": .string(""), "desc": .string(""),
                    "tg": .string(""), "sm": .array([]),
                    "primaries": .array([]), "secondaries": .array([]),
                    "muscleGroups": .array([]), "custom": .bool(true)
                ]))
            }
        }
        return all
    }

    // MARK: - Past sessions

    private static func session(daysAgo: Int, routineID: String, tag: String,
                                name: String,
                                exercises: [(String, Int, Int, Double)],
                                bodyweight: Double) -> JSONValue {
        let day = GymClock.day(Date().addingTimeInterval(-Double(daysAgo) * 86_400))
        let start = GymClock.milliseconds(
            Date().addingTimeInterval(-Double(daysAgo) * 86_400 - 3_600))
        let entries = exercises.enumerated().map { index, exercise -> JSONValue in
            let rows = (0..<exercise.1).map { _ -> JSONValue in
                .object(["w": .number(exercise.3), "r": .int(exercise.2),
                         "done": .bool(true), "phase": .string("work")])
            }
            return .object([
                "id": .string(exerciseID(tag, index)),
                "rid": .string(routineID),
                "topW": .number(exercise.3),
                "sets": .array(rows),
                "target": .object(["sets": .int(exercise.1), "reps": .int(exercise.2),
                                   "weight": .number(exercise.3)])
            ])
        }
        return .object([
            "id": .string("wdemo\(tag)\(daysAgo)"),
            "d": .string(day),
            "start": .int(start),
            "end": .int(start + 3_000_000),
            "routineIds": .array([.string(routineID)]),
            "routineId": .string(routineID),
            "name": .string(name),
            "bw": .number(bodyweight),
            "entries": .array(entries),
            "prs": .array([])
        ])
    }

    private static func bodyweightSeries() -> [JSONValue] {
        // Eight days, invented, gently trending.
        let values: [Double] = [71.8, 71.6, 71.9, 71.4, 71.2, 71.3, 70.9, 70.8]
        return values.enumerated().map { index, weight in
            let offset = Double(values.count - 1 - index) * 86_400
            let date = Date().addingTimeInterval(-offset)
            return .object(["d": .string(GymClock.day(date)),
                            "w": .number(weight),
                            "t": .int(GymClock.milliseconds(date))])
        }
    }

    // MARK: - The document

    private static func state() -> [String: JSONValue] {
        let a = "rdemoayusha"
        let b = "rdemoayushb"
        let c = "rdemoayushc"
        return [
            "_rev": .int(7),
            "_ts": .int(GymClock.milliseconds(Date().addingTimeInterval(-7_200))),
            "unit": .string("kg"),
            "routines": .array([
                .object(routine(id: a, name: "Ayush A", letter: "A",
                                exercises: dayA, tag: "a")),
                .object(routine(id: b, name: "Ayush B", letter: "B",
                                exercises: dayB, tag: "b")),
                .object(routine(id: c, name: "Ayush C", letter: "C",
                                exercises: dayC, tag: "c"))
            ]),
            // Javascript's weekday keys: "1" is Monday, Sunday is absent
            // because Sunday is his rest day. Saturday is deliberately a BARE
            // STRING rather than an array, so Demo exercises both shapes the
            // document is legitimately written in - the app has to read either
            // and write back whichever it found.
            "week": .object([
                "1": .array([.string(a)]), "2": .array([.string(b)]),
                "3": .array([.string(c)]), "4": .array([.string(a)]),
                "5": .array([.string(b)]), "6": .string(c)
            ]),
            "dayPlan": .object([:]),
            "workouts": .array([
                session(daysAgo: 4, routineID: a, tag: "a", name: "Ayush A",
                        exercises: dayA, bodyweight: 71.4),
                session(daysAgo: 3, routineID: b, tag: "b", name: "Ayush B",
                        exercises: dayB, bodyweight: 71.2),
                session(daysAgo: 2, routineID: c, tag: "c", name: "Ayush C",
                        exercises: dayC, bodyweight: 71.3)
            ]),
            "customEx": .array(customExercises()),
            "bodyweight": .array(bodyweightSeries()),
            "exWeights": .object([:]),
            "exNotes": .object([:]),
            "barWeights": .object([:]),
            "favEx": .array([]),
            "restSec": .int(90),
            "restPauseSec": .int(20),
            "reminder": .object(["on": .bool(false), "time": .string("18:00"),
                                 "tz": .null]),
            "effort": .null,
            "weekStart": .int(1),
            "theme": .string("dark"),
            "accent": .string("cyan"),
            "lang": .string("en"),
            "body": .string("metric"),
            "targetW": .number(70),
            "checkIn": .bool(true),
            "weighIn": .bool(true),
            "equipProfiles": .array([]),
            "activeEquipId": .null,
            "gymCards": .array([]),
            "lastGymCardId": .null
        ]
    }
}
