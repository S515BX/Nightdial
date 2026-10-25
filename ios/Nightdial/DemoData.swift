import Foundation

/// Small deterministic generator so the demo guide looks the same every time you open it on a given day.
struct SeededRandom {
    private var state: UInt32
    init(seed: UInt32) { state = seed }

    mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }

    mutating func pick<T>(_ list: [T]) -> T {
        list[Swift.min(list.count - 1, Int(next() * Double(list.count)))]
    }
}

struct DemoGroup {
    let id: String
    let name: String
    let base: Int
    let channels: [String]
    let durations: [Int]
    let titles: [String]
    let descriptions: [String]
    let ratings: [String]
    var episodic = false
    var movie = false
}

/// Invented channels and programs for the built-in demo playlist.
enum Demo {
    static let teams = ["Harbor FC", "Meridian United", "City Hawks", "Northgate Rovers", "Valley Athletic", "Ironbridge Town", "Coastline SC", "Stormers"]

    static let movies: [(String, String)] = [
        ("The Lantern Keeper", "A lighthouse keeper on a storm-bound island finds a logbook that rewrites her family history."),
        ("Northbound Express", "Strangers on an overnight train realize one of them isn't who they claim to be."),
        ("A Quiet Harbor", "A retired ferry captain and his estranged son spend one summer restoring an old boat."),
        ("Glass Orchard", "Two rival glassblowers are forced to share a workshop in a small mountain town."),
        ("The Cartographer's Daughter", "A young mapmaker sets out to finish the survey her father never completed."),
        ("Seven Winters", "A love story told across seven winters in the same snowed-in cabin."),
        ("Static Bloom", "A radio engineer picks up a signal that seems to come from tomorrow."),
        ("Iron Meridian", "A railway detective chases a gang of thieves across the frontier."),
        ("Paper Moons", "A struggling puppet theater gets one last chance at a sold-out show."),
        ("The Long Field", "A farming family fights to keep their land through a year of drought."),
        ("Neon Tide", "A night-shift paramedic is pulled into a citywide conspiracy."),
        ("Under Copper Skies", "Miners trapped underground keep each other going for nine days."),
        ("Saltwater Kings", "Two brothers inherit a failing fishing fleet and a dangerous debt."),
        ("The Last Ferry", "Passengers on the final crossing of the season are stranded by fog.")
    ]

    static let groups: [DemoGroup] = [
        DemoGroup(id: "news", name: "News", base: 101,
                  channels: ["Harbor News 24", "Civic Ledger", "Northgate World", "Metro Live 7", "Fieldline Weather"],
                  durations: [30, 30, 60, 60, 60],
                  titles: ["Morning Briefing", "The Midday Report", "World Desk", "Business Hour", "Evening News", "Late Edition", "Weather Watch", "Headlines on the Hour", "Politics Tonight", "The Week in Review", "Market Close", "Newsroom Live"],
                  descriptions: ["Live coverage of the day's top stories, with reports from correspondents across the region.", "The latest headlines, a look at the markets and a full regional weather forecast.", "Interviews and analysis on the decisions shaping the week ahead.", "Breaking news as it happens, with sport and weather on the hour."],
                  ratings: ["TV-G", "TV-PG"]),
        DemoGroup(id: "sports", name: "Sports", base: 201,
                  channels: ["Meridian Sports 1", "Meridian Sports 2", "Apex Motor", "Courtside", "Fairway Golf", "Kickoff Plus"],
                  durations: [60, 60, 90, 120],
                  titles: ["$match", "Matchday Countdown", "Grand Prix Qualifying", "Courtside Tonight", "Highlights Reel", "Golf: Final Round", "The Locker Room", "$match", "Classic Matches", "Transfer Talk"],
                  descriptions: ["Full live coverage with build-up, analysis and post-match reaction.", "Every goal, every chance and the big talking points from the weekend.", "Former players and coaches break down the biggest moments.", "Qualifying action as the drivers fight for pole position."],
                  ratings: ["TV-G"]),
        DemoGroup(id: "ent", name: "Entertainment", base: 301,
                  channels: ["Brightside", "Channel Ember", "Prime Comedy", "Studio Nine", "Hearth & Home", "Quiz Nation"],
                  durations: [30, 30, 60, 60],
                  titles: ["Crust & Crumb", "Kitchen Rivals", "Open House", "Quiz Rush", "Late Night with Mara Quill", "Second Chances", "The Renovators", "Flat 4B", "Talent Lane", "Market Hunters", "Weekend Escapes", "The Big Swap"],
                  descriptions: ["The contestants face their toughest round yet, and one of them goes home.", "A couple on a tight budget gets help turning a tired house into a home.", "Comedy and conversation with guests from film, music and television.", "Rent day, a broken boiler and an unexpected houseguest test the flatmates."],
                  ratings: ["TV-PG", "TV-14"], episodic: true),
        DemoGroup(id: "movies", name: "Movies", base: 401,
                  channels: ["Cinema Vault", "Reel Classics", "Midnight Features", "Matinee Gold", "Silver Screen Family"],
                  durations: [90, 105, 120, 120, 150],
                  titles: [], descriptions: [],
                  ratings: ["PG", "PG-13", "R"], movie: true),
        DemoGroup(id: "docs", name: "Documentary", base: 501,
                  channels: ["Northlight Docs", "Wild Atlas", "Deep Time", "Engineered", "Voyager History"],
                  durations: [60, 60, 60, 30],
                  titles: ["Wild Atlas: Tidal Flats", "Deep Time: The First Forests", "Engineered: Suspension Bridges", "Voyager: The Silk Roads", "Planet Underground", "Cold Frontiers", "The Clockmakers", "Coral Cities", "Rivers of Ice", "Migration Routes", "Inside the Observatory", "Lost Harbors"],
                  descriptions: ["Rare footage and expert voices follow a landscape through a single year.", "How the engineering works, told by the people who built it.", "A journey through deep time to the moment everything changed.", "Scientists race to understand a world that is changing fast."],
                  ratings: ["TV-G", "TV-PG"], episodic: true),
        DemoGroup(id: "kids", name: "Kids", base: 601,
                  channels: ["Pebble Kids", "Toon Harbor", "Little Lab", "Junior Jam"],
                  durations: [15, 30, 30],
                  titles: ["Pip & Pebble", "Rocket Rangers", "The Paper Zoo", "Little Lab Experiments", "Doodle Dash", "Bedtime Tales", "Sir Sprocket", "Moss & Moth", "Tug the Tugboat", "Shapes Ahoy"],
                  descriptions: ["Pip loses a kite and the whole harbor joins the search.", "The rangers build a rocket out of cardboard and big ideas.", "Songs, shapes and a surprise visitor at the zoo.", "A gentle story to wind down the day."],
                  ratings: ["TV-Y", "TV-Y7"], episodic: true),
        DemoGroup(id: "music", name: "Music", base: 701,
                  channels: ["Loud Room", "Vinyl Sundays", "Pulse Hits", "Encore Live"],
                  durations: [60, 60, 120],
                  titles: ["Non-stop Hits", "Vinyl Sessions", "Encore: Live at the Old Mill", "Top 40 Countdown", "Late Night Grooves", "Acoustic Corner", "Throwback Hour", "New Music Friday"],
                  descriptions: ["Back-to-back videos from the biggest artists right now.", "A full live set recorded in front of a small crowd.", "Deep cuts and classics, picked by the presenters."],
                  ratings: ["TV-PG"]),
        DemoGroup(id: "local", name: "Local", base: 801,
                  channels: ["Riverside 4", "Valley Public", "County Access"],
                  durations: [30, 60],
                  titles: ["Riverside Today", "Council Meeting", "Community Calendar", "High School Football", "Local Weather", "Valley Gardens", "Ask the Mayor", "Farm Report"],
                  descriptions: ["News, events and people from around the county.", "Live coverage of the evening council session.", "What is on this week: markets, meetings and matches."],
                  ratings: ["TV-G"])
    ]

    /// Public test streams from Apple and Mux. If they can't load, the demo draws its own picture instead.
    static let streams: [URL] = [
        URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!,
        URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
        URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!
    ]

    static let ticker = "Harbor bridge reopens after repairs   •   Markets steady ahead of rate decision   •   Rain clearing by evening, highs near 58°F   •   Council approves new library plans   •   Ferry timetable changes from Monday   •   "

    static func build() -> (channels: [Channel], groups: [ChannelGroup]) {
        var channels: [Channel] = []
        var out: [ChannelGroup] = []
        for (gi, g) in groups.enumerated() {
            for (k, name) in g.channels.enumerated() {
                var c = Channel(id: "d\(g.base + k)", num: g.base + k, name: name, logo: nil, groupId: g.id, epgId: "",
                                archive: k % 2 == 0, archiveDays: 3, hue: Double((gi * 47 + k * 23 + 200) % 360))
                c.demoKind = g.id
                c.demoStream = streams[(gi + k) % streams.count]
                channels.append(c)
            }
            out.append(ChannelGroup(id: g.id, name: g.name, count: g.channels.count))
        }
        return (channels, out)
    }

    static func schedule(for ch: Channel, from rangeStart: Date, to rangeEnd: Date) -> [Program] {
        guard let g = groups.first(where: { $0.id == ch.demoKind }) else { return [] }
        let dayStart = Calendar.current.startOfDay(for: rangeStart)
        var t = dayStart.addingTimeInterval(-2 * 3600)
        let end = rangeEnd.addingTimeInterval(6 * 3600)
        var r = SeededRandom(seed: fnv1a("\(ch.id):\(Int(dayStart.timeIntervalSince1970))"))
        var out: [Program] = []
        var last = ""
        var season = 1 + Int(r.next() * 5)
        var episode = 1 + Int(r.next() * 9)
        while t < end {
            var minutes = r.pick(g.durations)
            var title = ""
            var desc = ""
            var ep = ""
            var live = false
            if g.movie {
                var m = r.pick(movies)
                if m.0 == last { m = r.pick(movies) }
                title = m.0
                desc = m.1
                ep = String(1978 + Int(r.next() * 46))
            } else {
                title = r.pick(g.titles)
                if title == last { title = r.pick(g.titles) }
                desc = r.pick(g.descriptions)
                if title == "$match" {
                    let a = r.pick(teams)
                    var b = r.pick(teams)
                    if b == a { b = teams[((teams.firstIndex(of: a) ?? 0) + 3) % teams.count] }
                    title = "Live: \(a) vs \(b)"
                    live = true
                    minutes = 120
                    desc = "\(a) host \(b). Full live coverage with build-up, analysis and post-match reaction."
                }
                if g.episodic {
                    ep = "S\(season) E\(episode)"
                    episode += 1
                    if episode > 12 { episode = 1; season += 1 }
                }
                if g.id == "news" && r.next() < 0.55 { live = true }
            }
            last = title
            let isNew = !live && r.next() < 0.22
            let p = Program(start: t, end: t.addingTimeInterval(Double(minutes) * 60), title: title, desc: desc,
                            episode: ep, rating: r.pick(g.ratings), live: live, isNew: isNew)
            out.append(p)
            t = p.end
        }
        return out
    }
}
