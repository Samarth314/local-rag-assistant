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

    // MARK: - The catalogue

    /// id, name, body part, equipment, gif filename. Twenty-four real rows out
    /// of openGym's 1324, read from the live `/api/gym/library` on 2026-09-19
    /// and kept in the server's own order (case-folded by name, id as the
    /// tiebreak) so Demo's picker scrolls the way production's does.
    ///
    /// Real ids and real filenames, so a Demo row added to a routine would be
    /// a valid entry and a Demo thumbnail loads the same animation the phone
    /// loads in Live - the media is public static content on openGym's web
    /// container, not something the mini proxies.
    private static let catalogue: [(String, String, String, String, String)] = [
        ("0001", "3/4 sit-up", "waist", "body weight", "0001-2gPfomN.gif"),
        ("0003", "air bike", "waist", "body weight", "0003-1ZFqTDN.gif"),
        ("1010", "band straight leg deadlift", "back", "band", "1010-KUaoUV8.gif"),
        ("0025", "barbell bench press", "chest", "barbell", "0025-EIeI8Vf.gif"),
        ("0032", "barbell deadlift", "upper legs", "barbell", "0032-ila4NZS.gif"),
        ("0043", "barbell full squat", "upper legs", "barbell", "0043-qXTaZnJ.gif"),
        ("0202", "cable rear delt row (stirrups)", "shoulders", "cable", "0202-yUdIGNs.gif"),
        ("0245", "cable underhand pulldown", "back", "cable", "0245-xBYcQHj.gif"),
        ("0272", "crunch (on stability ball, arms straight)", "waist", "stability ball",
         "0272-Sn8wxAI.gif"),
        ("0290", "dumbbell bench seated press", "shoulders", "dumbbell", "0290-3d7wHyd.gif"),
        ("0305", "dumbbell decline shrug", "back", "dumbbell", "0305-cwsAI4G.gif"),
        ("0319", "dumbbell incline fly", "chest", "dumbbell", "0319-ESOd5Pl.gif"),
        ("0863", "dumbbell lying external shoulder rotation", "shoulders", "dumbbell",
         "0863-bmBf7LN.gif"),
        ("0385", "dumbbell reverse wrist curl", "lower arms", "dumbbell", "0385-BLCvwr2.gif"),
        ("0421", "dumbbell standing one arm concentration curl", "upper arms", "dumbbell",
         "0421-8fgqP5a.gif"),
        ("0473", "hanging pike", "waist", "body weight", "0473-nuBF9MO.gif"),
        ("0508", "janda sit-up", "waist", "body weight", "0508-1GPHRyK.gif"),
        ("0577", "lever chest press", "chest", "leverage machine", "0577-T0yTjgW.gif"),
        ("0602", "lever seated reverse fly", "shoulders", "leverage machine", "0602-myfUsKf.gif"),
        ("0652", "pull-up", "back", "body weight", "0652-lBDjFxJ.gif"),
        ("0664", "push-up to side plank", "waist", "body weight", "0664-KhHJ338.gif"),
        ("0709", "side hip (on parallel bars)", "waist", "body weight", "0709-jTkSc6o.gif"),
        ("0811", "trap bar deadlift", "upper legs", "trap bar", "0811-jQGwmxN.gif"),
        ("1460", "walking lunge", "upper legs", "body weight", "1460-IZVHb27.gif")
    ]

    static func library() -> GymLibrary {
        GymLibrary(mediaBase: "https://gym.ataru.aryasasikumar.com/gif/",
                   exercises: catalogue.map {
                       GymLibraryEntry(id: $0.0, name: $0.1, bodyPart: $0.2,
                                       equipment: $0.3, gif: $0.4)
                   })
    }

    /// The one CATALOGUE exercise each routine ends with.
    ///
    /// The rest of the fixture is custom exercises on purpose (see above), and
    /// a document of nothing but customs renders no animation anywhere - which
    /// would make the GIF work unreviewable in Demo. One catalogue id per
    /// routine puts both paths on the same screen: rows with a demo, and rows
    /// that correctly have none.
    private static let catalogueExtras: [String: (String, Int, Int, Double)] = [
        "a": ("0043", 2, 8, 60),      // barbell full squat
        "b": ("0652", 2, 8, 0),       // pull-up
        "c": ("0003", 2, 20, 0)       // air bike
    ]

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
        var configs = exercises.enumerated().map { index, exercise -> JSONValue in
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
        if let extra = catalogueExtras[tag] {
            var config: [String: JSONValue] = [
                "id": .string(extra.0), "sets": .int(extra.1),
                "reps": .int(extra.2), "weight": .number(extra.3)
            ]
            if extra.3 == 0 { config["bodyweight"] = .bool(true) }
            configs.append(.object(config))
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
            // `emoji` holds openGym's ICON NAME, not an emoji: these three
            // strings are the ones in Arya's own document, read from the live
            // `/api/gym/state` on 2026-09-19. They are here verbatim BECAUSE
            // they are the bug - a fixture carrying "A", "B", "C" renders a
            // week strip that looks perfect and proves nothing, which is
            // exactly how "barbell isn't even fitting on one line" reached
            // him. `GymRoutine.shortLabel` is what turns these back into one
            // character.
            "routines": .array([
                .object(routine(id: a, name: "Ayush A", letter: "barbell",
                                exercises: dayA, tag: "a")),
                .object(routine(id: b, name: "Ayush B", letter: "pullup",
                                exercises: dayB, tag: "b")),
                .object(routine(id: c, name: "Ayush C", letter: "abs",
                                exercises: dayC, tag: "c"))
            ]),
            // Javascript's weekday keys: "1" is Monday, Sunday is absent
            // because Sunday is his rest day. BARE STRINGS, which is what the
            // live document actually holds - all six of his slots are written
            // that way. Thursday is kept as a one-element array so Demo still
            // exercises both shapes the document is legitimately written in;
            // the app has to read either and write back whichever it found.
            "week": .object([
                "1": .string(a), "2": .string(b),
                "3": .string(c), "4": .array([.string(a)]),
                "5": .string(b), "6": .string(c)
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
