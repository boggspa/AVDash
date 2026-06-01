import Foundation
import PodcastPreviewCore

/// Provides human-readable copy for hardware insight rows using stable
/// template pools seeded from quantised metric values.
///
/// The same underlying data always produces the same phrase within a session
/// and across launches for identical inputs. Different load levels, time
/// windows, and metric types produce naturally varied phrasing by drawing
/// from per-condition pools of 3–4 alternatives.
///
/// **FoundationModels migration path (macOS 26 / Tahoe+)**
/// Add `async` variants alongside each function — e.g.
/// `cpuLoadDescriptionAsync(for averageUsage: Double) async -> String` —
/// that call `LanguageModelSession` with a structured prompt built from the
/// same scalar inputs. In `HardwareInsightsCard.loadInsights()`, check
/// `SystemLanguageModel.isAvailable` and await the async variants when
/// possible, falling back to the synchronous pool methods here.
struct HardwareInsightCopywriter {

    let window: HardwareInsightWindow

    // MARK: - CPU

    func cpuLoadDescription(for averageUsage: Double) -> String {
        switch averageUsage {
        case ..<0.20:
            return pick([
                "CPU kept its cool — barely any demand",
                "Light processor load with plenty of headroom",
                "CPU coasted through without breaking a sweat",
                "Minimal demand — cores spent most of the time idling",
                "Quiet window for the processor overall",
                "Seriously, is this thing on? CPU had almost nothing to do",
                "Processor had so little to do it probably started questioning its purpose",
                "CPU was basically a very expensive space heater this stretch — just not a warm one",
                "CPU is currently accepting applications for real work",
                "Processor took a well-deserved vacation this window",
                "Cores were practically twiddling their silicon thumbs",
            ], value: averageUsage, salt: 1)
        case ..<0.45:
            return pick([
                "Moderate CPU use overall",
                "Steady mid-range pace — nothing the processor couldn't handle",
                "Regular workloads kept CPU ticking along comfortably",
                "CPU hummed along at a sustainable clip",
                "Balanced processor demand across the window",
                "CPU showed up, did its thing, went home — a solid day's work",
                "Processor handled everything thrown at it without drama",
                "Respectable mid-range output — not coasting, not sweating",
                "Just enough work to keep the CPU from falling asleep",
                "A gentle jog for the processor, nothing strenuous",
                "CPU enjoyed a leisurely stroll through its task list",
            ], value: averageUsage, salt: 1)
        case ..<0.70:
            return pick([
                "CPU had its hands full for much of the window",
                "Above-average demand kept the processor busy",
                "Heavier sustained load — cores earned their keep",
                "CPU put in solid work across this stretch",
                "Processor demand ran hotter than typical",
                "CPU was earning its electricity bill this stretch",
                "Cores were pulling their weight — no slackers here",
                "Steady heavy lifting throughout — the processor didn't get to coast",
                "The processor handled sustained work without much idle time",
                "Cores were juggling a healthy amount of work",
                "CPU got a solid workout without hitting the redline",
            ], value: averageUsage, salt: 1)
        default:
            return pick([
                "CPU ran flat out for most of the window",
                "Cores were pinned — heavy demand throughout",
                "Near-peak pressure with little breathing room",
                "CPU was pushed hard and didn't get much rest",
                "High sustained load — processor barely came up for air",
                "CPU was sweating bullets — sustained near-peak demand throughout",
                "The processor ran like it owed someone money",
                "Every core was fully committed — nowhere to hide",
                "CPU was clinging on for dear life",
                "The processor is formally requesting a raise after that",
                "Cores were running a marathon at sprint pace",
            ], value: averageUsage, salt: 1)
        }
    }

    // MARK: - Memory

    func memoryLoadDescription(for averageUsage: Double) -> String {
        switch averageUsage {
        case ..<0.50:
            return pick([
                "Plenty of RAM to spare across the window",
                "Memory had room to breathe — well below capacity",
                "Comfortable headroom with no signs of strain",
                "RAM sat easy with capacity to spare",
                "Light memory footprint throughout",
                "Memory could have fit a lot more — it's feeling slightly underutilised",
                "RAM had more headroom than a penthouse suite",
                "Spacious memory conditions — nothing even approaching a squeeze",
                "RAM is basically a ghost town right now",
                "Memory so empty you could hear an echo",
                "Plenty of room for activities in RAM",
                "RAM is absolutely bursting at the seams",
                "Memory is screaming for someone to close a few Chrome tabs",
                "RAM is officially at maximum occupancy — no vacancies",
            ], value: averageUsage, salt: 2)
        case ..<0.75:
            return pick([
                "Moderate memory demand with healthy headroom",
                "RAM stayed in a balanced mid-range zone",
                "Memory ticked along at a manageable level",
                "Steady occupancy — nothing alarming",
                "Reasonable memory use without pressure building",
                "Memory kept the receipts — managed everything comfortably",
                "RAM handled its workload without once breaking a sweat",
                "Solid middle-ground memory use — efficient without being restrictive",
                "RAM is comfortably full, like a good restaurant",
                "Memory is pulling a solid shift without complaining",
                "A healthy amount of data moving through the RAM",
            ], value: averageUsage, salt: 2)
        case ..<0.90:
            return pick([
                "RAM started feeling the squeeze",
                "Memory climbed into the upper range for stretches",
                "Higher than average occupancy — headroom was thin",
                "RAM was well-populated with less room to manoeuvre",
                "Memory ran fairly full across the window",
                "RAM was rationing space — every byte accounted for",
                "Memory was filling up like a suitcase packed at the last minute",
                "Not quite bursting but getting there — headroom was slim",
                "RAM is starting to play Tetris to fit everything in",
                "Memory is getting cozy — personal space is limited",
                "RAM is currently playing a high-stakes game of musical chairs",
            ], value: averageUsage, salt: 2)
        default:
            return pick([
                "RAM was packed to the rafters",
                "Memory stayed pinned near its ceiling",
                "Sustained near-capacity use — not much give left",
                "RAM was under real pressure throughout",
                "Memory had almost nowhere left to go",
                "Memory stayed crowded across the window",
                "RAM is close to the point where one more large app would matter",
                "Memory was stuffed to the absolute limit — compression working overtime",
                "RAM is absolutely bursting at the seams",
                "Memory is screaming for someone to close a few Chrome tabs",
                "RAM is officially at maximum occupancy — no vacancies",
            ], value: averageUsage, salt: 2)
        }
    }

    func memoryPressureDescription(spikeBucketCount: Int, peakValue: Double) -> String {
        if spikeBucketCount == 0 && peakValue < 0.33 {
            return pick([
                "Pressure stayed nominal — no compression drama",
                "Memory pressure kept a low profile throughout",
                "No notable compression or pressure events",
                "System memory pressure stayed comfortably green",
                "Pressure was a non-event this window",
            ], value: peakValue, salt: 3)
        }
        if peakValue >= 0.66 {
            return pick([
                "Pressure climbed to serious levels",
                "Memory pressure hit the danger zone at peak",
                "Heavy compression kicked in — system was feeling it",
                "Serious memory pressure — the system leaned hard on swap",
                "Pressure wasn't messing around this window",
            ], value: peakValue, salt: 3)
        }
        if spikeBucketCount > 0 {
            let suffix = spikeBucketCount == 1 ? "window" : "windows"
            return "Pressure spiked in \(spikeBucketCount) \(suffix)"
        }
        return pick([
            "Pressure rose briefly but settled back down",
            "A few compression blips — nothing sustained",
            "Brief pressure events dotted the timeline",
            "Pressure ticked up at times without lingering",
            "Minor pressure flare-ups came and went",
        ], value: peakValue, salt: 3)
    }

    // MARK: - GPU

    func gpuLoadDescription(for averageUsage: Double) -> String {
        switch averageUsage {
        case ..<0.15:
            return pick([
                "GPU barely broke a sweat this window",
                "Graphics processor spent most of its time napping",
                "Very little GPU demand — mostly coasting",
                "GPU sat idle with nothing much to render",
                "Quiet stretch for the graphics pipeline",
                "GPU filed for boredom leave — absolutely nothing to render",
                "Graphics card was about as busy as a sundial at midnight",
                "GPU was on screen-saver mode — barely a pixel moved",
                "GPU is currently reevaluating its life choices",
                "Graphics card is taking a prolonged siesta",
                "GPU pixels are gathering dust",
                "GPU is painting a masterpiece, taking its time",
                "Solid rendering session — the GPU is in the zone",
                "Graphics pipeline is flowing nicely",
                "GPU is rendering like its life depends on it",
                "Graphics card is throwing pixels at the screen as fast as it can",
                "GPU is basically a jet engine right now",
            ], value: averageUsage, salt: 4)
        case ..<0.40:
            return pick([
                "Light but steady GPU engagement throughout",
                "GPU handled modest workloads without fuss",
                "Low-key graphics demand across the window",
                "GPU ticked over at a comfortable pace",
                "Modest rendering work — nothing strenuous",
                "GPU showed willing but wasn't really tested",
                "Light rendering duties — the pipeline had plenty in reserve",
                "Relaxed graphics load — GPU was happy, unbothered",
                "GPU is doing some light sketching, nothing major",
                "A casual stroll through the rendering pipeline",
                "GPU is humming a happy little tune",
            ], value: averageUsage, salt: 4)
        case ..<0.70:
            return pick([
                "GPU stayed busy with consistent mid-range load",
                "Steady graphics demand kept the pipeline moving",
                "GPU put in a solid shift across the window",
                "Moderate sustained GPU activity throughout",
                "Graphics workload held at a working clip",
                "GPU was meaningfully engaged — not coasting, not struggling",
                "Solid sustained render load — the GPU earned its place",
                "Steady pipeline activity with room to spare",
                "GPU is painting a masterpiece, taking its time",
                "Solid rendering session — the GPU is in the zone",
                "Graphics pipeline is flowing nicely",
            ], value: averageUsage, salt: 4)
        default:
            return pick([
                "GPU was firing on all cylinders",
                "Heavy sustained load — the graphics pipeline earned its keep",
                "GPU ran hard with little downtime",
                "Significant GPU demand across the board",
                "Graphics processor was pushed to its limits",
                "GPU was absolutely cooking — in every sense of the word",
                "Graphics processor was running harder than a deadline",
                "Pipeline fully saturated — the GPU had no time to think",
                "GPU is rendering like its life depends on it",
                "Graphics card is throwing pixels at the screen as fast as it can",
                "GPU is basically a jet engine right now",
            ], value: averageUsage, salt: 4)
        }
    }

    func gpuActiveAppsDescription(appNames: [String]) -> String? {
        guard !appNames.isEmpty else { return nil }

        let count = appNames.count
        if count == 1 {
            return pick([
                "\(appNames[0]) is actively drawing GPU time",
                "GPU cycles are going to \(appNames[0])",
                "\(appNames[0]) has the GPU's attention",
                "\(appNames[0]) is keeping the GPU occupied",
            ], value: Double(count), salt: 10)
        }

        let listed = appNames.prefix(3).joined(separator: ", ")
        let suffix = count > 3 ? " and \(count - 3) more" : ""
        return pick([
            "\(listed)\(suffix) are sharing GPU time",
            "GPU is splitting cycles across \(listed)\(suffix)",
            "Active GPU clients: \(listed)\(suffix)",
            "\(listed)\(suffix) are all tapping the graphics pipeline",
        ], value: Double(count), salt: 10)
    }

    // MARK: - Neural Engine

    func aneLoadDescription(for averageActivity: Double) -> String {
        switch averageActivity {
        case ..<0.10:
            return pick([
                "Neural Engine had a genuinely restful window",
                "ANE sat dormant — no ML models came knocking",
                "Very little machine-learning demand to speak of",
                "Neural Engine barely registered a pulse",
                "Quiet spell for on-device inference",
                "ANE was on standby — the models took the day off",
                "Neural Engine had such a quiet session it briefly considered a career change",
                "Not a single model had the audacity to knock on the ANE's door",
            ], value: averageActivity, salt: 5)
        case ..<0.40:
            return pick([
                "Neural Engine clocked in for occasional bursts",
                "Periodic ANE activity between quiet stretches",
                "Intermittent inference work dotted the timeline",
                "Light but present Neural Engine engagement",
                "ANE saw sporadic action without sustained load",
                "Neural Engine poked its head up a few times then went back to sleep",
                "Occasional inference jobs kept the ANE from getting too comfortable",
                "Sporadic ML work — the ANE was part-time this stretch",
            ], value: averageActivity, salt: 5)
        case ..<0.70:
            return pick([
                "Neural Engine stayed busy with steady ML demand",
                "Consistent machine-learning workloads kept the ANE engaged",
                "ANE put in reliable work across the window",
                "Moderate sustained neural processing throughout",
                "On-device inference held at a working pace",
                "Neural Engine was meaningfully occupied — models running at a steady clip",
                "ANE was in its element — enough ML work to stay sharp",
                "Solid inference workload throughout — the dedicated silicon earned it",
            ], value: averageActivity, salt: 5)
        default:
            return pick([
                "Neural Engine clocked in for overtime",
                "ANE was under heavy sustained load — models kept it busy",
                "Intensive on-device inference dominated the window",
                "Neural Engine worked hard with little time off",
                "Heavy ML demand — the ANE earned its silicon",
                "ANE was crunching models like there's no tomorrow",
                "Neural Engine went full beast mode — non-stop inference throughout",
                "On-device ML was relentless — the Neural Engine barely got a moment to breathe",
            ], value: averageActivity, salt: 5)
        }
    }

    // MARK: - Disk

    func diskActivityDescription(readAvg: Double, writeAvg: Double) -> String {
        let combined = readAvg + writeAvg
        switch combined {
        case ..<1:
            return pick([
                "Storage barely got a look-in this window",
                "Disk sat quiet with very little I/O to speak of",
                "Minimal read or write demand throughout",
                "The drive had an easy ride — near-zero throughput",
                "Almost no disk activity worth noting",
                "Disk was peacefully ignored for the whole session",
                "Storage was so underworked it might as well have been unplugged",
                "The NVMe did absolutely nothing and was fine with that",
                "The SSD is wondering if you forgot it exists",
                "Disk is enjoying a moment of profound silence",
                "Disk is practically glowing red from all the I/O",
                "Storage is moving data like a hyperactive librarian",
            ], value: combined, salt: 6)
        case ..<10:
            return pick([
                "Low but steady I/O throughput across the window",
                "Light disk activity — nothing that would stress the drive",
                "Modest storage access with a gentle read/write cadence",
                "Disk ticked over at a comfortable pace",
                "Light I/O demand without any notable bursts",
                "A trickle of reads and writes — nothing to alarm the drive",
                "Storage activity was polite and unhurried throughout",
                "Gentle I/O cadence — the kind the drive barely notices",
                "Storage is doing some light reading",
                "A gentle trickle of data, nothing to worry the drive",
            ], value: combined, salt: 6)
        case ..<50:
            return pick([
                "Steady disk throughput — the drive stayed productively busy",
                "Regular I/O activity kept storage engaged",
                "Moderate sustained throughput across reads and writes",
                "Consistent mid-range disk demand throughout",
                "Storage handled a healthy workload without strain",
                "Disk was doing real work — meaningful throughput without drama",
                "Solid sustained I/O — the drive was properly employed",
                "Healthy read/write mix — storage was pulling its weight",
                "Disk is shuffling papers at a respectable speed",
                "Storage is keeping busy with a steady stream of requests",
            ], value: combined, salt: 6)
        default:
            return pick([
                "Disk was churning through serious I/O volume",
                "Heavy sustained throughput — the drive earned its keep",
                "Storage took a hammering across the window",
                "Intensive disk activity with high read/write demand",
                "The drive didn't get much downtime this stretch",
                "Storage was absolutely going for it — high sustained throughput",
                "Disk was reading and writing like the deadline was yesterday",
                "Serious I/O volume — the drive was very much not bored",
                "Disk is practically glowing red from all the I/O",
                "Storage is moving data like a hyperactive librarian",
            ], value: combined, salt: 6)
        }
    }

    // MARK: - Network

    func networkActivityDescription(upAvg: Double, downAvg: Double) -> String {
        let combined = upAvg + downAvg
        switch combined {
        case ..<0.1:
            return pick([
                "Network idle for most of the time window",
                "Barely a packet crossed the wire",
                "Near-zero traffic — the NIC had nothing to do",
                "Very little data moved in either direction",
                "Network sat dormant across the window",
                "Network was as quiet as a library on a Sunday",
                "Connection had nothing to send and nowhere to go",
                "NIC was twiddling its virtual thumbs — not a byte to show for it",
                "Network is so quiet you could hear a pin drop",
                "Wi-Fi antenna is basically just a decorative stick right now",
                "A polite whisper of packets across the network",
                "Network is sending the occasional postcard",
                "Solid stream of data flowing through the pipes",
                "Network is having a lively conversation",
                "Network is drinking from the firehose",
                "Packets are flying faster than a flock of startled pigeons",
            ], value: combined, salt: 7)
        case ..<1:
            return pick([
                "Light network traffic with quiet stretches in between",
                "Low throughput — just a trickle of data",
                "Modest bandwidth use without any real spikes",
                "A gentle hum of network activity overall",
                "Light but present data transfer throughout",
                "A polite trickle of data — nothing to trouble the router",
                "Network was barely whispering — low throughput throughout",
                "Occasional bursts of data with long silences between",
                "A polite whisper of packets across the network",
                "Network is sending the occasional postcard",
            ], value: combined, salt: 7)
        case ..<10:
            return pick([
                "Steady network engagement at moderate bandwidth",
                "Regular data flow kept the connection busy",
                "Consistent mid-range throughput across the window",
                "Network stayed productively occupied",
                "Moderate sustained bandwidth use throughout",
                "A comfortable flow of data — the connection was usefully employed",
                "Network was ticking over nicely — not maxed, not idle",
                "Steady transfer activity without pushing the limits",
                "Solid stream of data flowing through the pipes",
                "Network is having a lively conversation",
            ], value: combined, salt: 7)
        default:
            return pick([
                "Heavy bandwidth demand — the pipe was well used",
                "Sustained high-throughput traffic across the window",
                "Network was moving serious data volume",
                "Intensive transfer activity kept the connection saturated",
                "The network link earned its keep this stretch",
                "Pipes were absolutely stuffed — high sustained throughput",
                "Network link was working harder than a pizza delivery driver on game night",
                "Serious data movement — the connection barely got a breather",
                "Network is drinking from the firehose",
                "Packets are flying faster than a flock of startled pigeons",
            ], value: combined, salt: 7)
        }
    }

    // MARK: - Power

    func powerLoadDescription(for averagePower: Double) -> String {
        switch averagePower {
        case ..<8:
            return pick([
                "Low average system draw — sipping power quietly",
                "System stayed lean and efficient throughout",
                "Very light energy footprint across the window",
                "Power draw barely registered above idle",
                "Efficient run — the battery would approve",
                "System was practically solar-powered it was that frugal",
                "Power draw so low the charger had an easy time",
                "Miserly energy use — the efficiency stats are genuinely impressive",
            ], value: averagePower, salt: 8)
        case ..<18:
            return pick([
                "Balanced power draw at a sustainable level",
                "Moderate energy consumption without heavy spikes",
                "System ran at a comfortable wattage throughout",
                "Power use sat in the sensible middle ground",
                "Typical day-to-day draw — nothing extravagant",
                "Reasonable energy budget — not frugal, not wasteful",
                "Power consumption behaved like a responsible adult throughout",
                "Steady moderate draw — the kind of efficiency that's easy to like",
            ], value: averagePower, salt: 8)
        case ..<30:
            return pick([
                "Power draw climbed during active stretches",
                "Above-average energy consumption for this window",
                "System pulled more watts than usual",
                "Elevated draw — workloads pushed the power budget up",
                "Higher than typical wattage across the board",
                "System was spending watts a bit more freely this stretch",
                "Power budget had a workout — heavier draw than a typical session",
                "Elevated consumption throughout — the workload was making itself known",
            ], value: averagePower, salt: 8)
        default:
            return pick([
                "System was drinking watts at a serious pace",
                "Heavy sustained power draw throughout the window",
                "Energy consumption stayed firmly in the red zone",
                "High wattage demand — the PSU was earning its keep",
                "Consistently elevated draw with no sign of easing off",
                "System went full send on the power consumption this stretch",
                "Watts were disappearing at an impressive rate — something was working hard",
                "High sustained draw — the kind of session that shows up on your energy bill",
            ], value: averagePower, salt: 8)
        }
    }

    // MARK: - Thermals

    func thermalDescription(peakLevel: Double, spikeBucketCount: Int) -> String {
        switch peakLevel {
        case ..<0.10:
            return pick([
                "Cooling system had an easy time — thermals stayed nominal",
                "Thermal conditions remained comfortable throughout",
                "No heat worth worrying about across the window",
                "System kept its cool without the fans breaking a sweat",
                "Thermals were a non-issue this stretch",
                "Fans barely registered a heartbeat — thermally pristine",
                "Cool as a cucumber from start to finish",
                "Thermal performance was quietly excellent — not a warm moment",
                "Thermals are basically in a cryo-sleep",
                "System is cooler than a polar bear\'s toenails",
                "A pleasant, balmy breeze from the fans",
                "System is pleasantly warm, like a sunbathing cat",
                "System is basically a portable space heater",
                "Fans have engaged hover mode",
            ], value: peakLevel, salt: 9)
        case ..<0.50:
            return pick([
                "Thermals warmed up during busier periods",
                "Some thermal activity but nothing sustained",
                "Brief warmth picked up and settled back down",
                "Moderate heat events — the cooling coped fine",
                "Fair thermal pressure during active stretches",
                "A little warmth here and there — nothing the fans couldn't handle",
                "Thermals ticked up at times but never got dramatic about it",
                "Mild heat events — the cooling system shrugged them off",
                "A pleasant, balmy breeze from the fans",
                "System is pleasantly warm, like a sunbathing cat",
            ], value: peakLevel, salt: 9)
        case ..<0.85:
            return pick([
                "Thermals hit serious territory at peak",
                "System ran warm — the cooling system was working for it",
                "Significant heat during intensive periods",
                "Thermal conditions pushed well above comfortable",
                "Things got toasty during heavy workloads",
                "Fans had something to say about this one — real heat events",
                "Thermal conditions were notable — not critical, but not comfortable",
                "The system ran warm enough that the cooling earned its salary",
                "Things are getting spicy in the chassis",
                "Fans are clearing their throats, preparing for a solo",
            ], value: peakLevel, salt: 9)
        default:
            return pick([
                "Thermals flirted with critical — the system ran hot",
                "Serious thermal stress was sustained for stretches",
                "System pushed right up against its thermal ceiling",
                "Critical heat levels — cooling was maxed out",
                "Thermals went into the red zone and stayed there",
                "The system got properly hot — thermal throttling territory",
                "Serious heat — this was a session the cooling system will remember",
                "Thermals were in alarming territory for stretches — the silicon felt it",
                "System is basically a portable space heater",
                "Fans have engaged hover mode",
            ], value: peakLevel, salt: 9)
        }
    }

    func thermalHeadline(for averageLevel: Double) -> String {
        switch averageLevel {
        case ..<0.10:
            return pick([
                "Cool and comfortable",
                "Thermals mostly nominal",
                "Well within thermal limits",
                "Running cool throughout",
            ], value: averageLevel, salt: 10)
        case ..<0.50:
            return pick([
                "Mild thermal activity",
                "Thermals mostly fair",
                "Manageable thermal conditions",
                "A touch of warmth at times",
            ], value: averageLevel, salt: 10)
        case ..<0.85:
            return pick([
                "Thermals often serious",
                "Significant thermal events",
                "Notable heat during active use",
                "System ran warm for stretches",
            ], value: averageLevel, salt: 10)
        default:
            return pick([
                "Thermals frequently critical",
                "Persistent thermal stress",
                "Near-limit thermal conditions",
                "Running hot across the board",
            ], value: averageLevel, salt: 10)
        }
    }

    // MARK: - Busiest period

    func busiestSummary(daypartLabel: String?, formattedHour: String?) -> String? {
        switch (daypartLabel, formattedHour) {
        case let (daypart?, hour?):
            return pickBySeed([
                "Most activity in the \(daypart) near \(hour)",
                "Peak demand hit in the \(daypart) around \(hour)",
                "Heaviest use landed around \(hour) in the \(daypart)",
                "Things peaked in the \(daypart) near \(hour)",
                "The \(daypart) around \(hour) was the busiest stretch",
            ], seed: stableHash(daypart + hour))
        case let (daypart?, nil):
            return pickBySeed([
                "Peak demand landed in the \(daypart)",
                "Most active during the \(daypart)",
                "The \(daypart) was the busiest stretch",
                "Heaviest use fell in the \(daypart)",
            ], seed: stableHash(daypart))
        case let (nil, hour?):
            return pickBySeed([
                "Peak activity around \(hour)",
                "Busiest stretch was near \(hour)",
                "Most demand clustered around \(hour)",
                "Things ramped up around \(hour)",
            ], seed: stableHash(hour))
        case (nil, nil):
            return nil
        }
    }

    func dynamicsDescription(for insight: HardwareMetricInsight, noun: String) -> String? {
        let seed = patternSeed(for: insight, salt: stableHash(noun) & 0xFF)
        let value = insight.variabilityRatio ?? 0

        switch insight.activityCadence {
        case .quiet:
            if let peakRecency = insight.peakRecencyRatio, peakRecency >= 0.75 {
                return pick([
                    "Most of the window was quiet, with only a late flicker of activity",
                    "\(noun) stayed subdued until a small end-of-window stir",
                    "It was calm for ages, then briefly remembered it had a job",
                ], value: value, salt: 201, extraSeed: seed)
            }
            if insight.longestIdleStreak >= 3 {
                return pick([
                    "Long calm stretches dominated the timeline",
                    "\(noun) spent an extended stretch doing almost nothing at all",
                    "The quiet periods weren't brief cameos — they took over the session",
                ], value: Double(insight.longestIdleStreak), salt: 202, extraSeed: seed)
            }
            return pick([
                "Load stayed low and never properly gathered momentum",
                "\(noun) mostly idled with only the occasional nudge of activity",
                "This one drifted along quietly without ever making a scene",
            ], value: value, salt: 203, extraSeed: seed)

        case .bursty:
            switch insight.trendDirection {
            case .rising:
                return pick([
                    "Activity arrived in bursts and got punchier toward the end",
                    "\(noun) came in waves, with the busier ones landing later",
                    "The session built through repeated bursts rather than one long push",
                ], value: value, salt: 204, extraSeed: seed)
            case .falling:
                return pick([
                    "The busiest bursts landed early before things settled down",
                    "\(noun) opened loudly, then backed off after the early spikes",
                    "Short sharp bursts did most of their damage early on",
                ], value: value, salt: 205, extraSeed: seed)
            case .oscillating, .flat:
                return pick([
                    "It kept lurching between quiet and busy without picking a lane",
                    "\(noun) bounced around in waves rather than holding a steady pace",
                    "Bursts kept interrupting the quieter stretches all session long",
                ], value: value, salt: 206, extraSeed: seed)
            @unknown default:
                return pick([
                    "\(noun) kept changing tempo without settling into one pattern",
                    "The cadence wandered around enough to keep things interesting",
                    "It never quite landed on a single rhythm",
                ], value: value, salt: 216, extraSeed: seed)
            }

        case .steady:
            switch insight.trendDirection {
            case .rising:
                return pick([
                    "The pace was orderly, but it ramped up as the window went on",
                    "\(noun) built gradually rather than exploding into life all at once",
                    "This was a smooth climb, not a sudden jump",
                ], value: value, salt: 207, extraSeed: seed)
            case .falling:
                return pick([
                    "It did the heavier lifting early, then eased off cleanly",
                    "\(noun) started sturdier and gradually relaxed later in the window",
                    "The tempo softened over time instead of falling off a cliff",
                ], value: value, salt: 208, extraSeed: seed)
            case .oscillating:
                return pick([
                    "The average looked tidy even though the underlying pace kept wobbling",
                    "\(noun) was steady on paper but a bit fidgety underneath",
                    "It never got chaotic, but the cadence still wandered around",
                ], value: value, salt: 209, extraSeed: seed)
            case .flat:
                return pick([
                    "The pace was consistent from one stretch to the next",
                    "\(noun) settled into a reliable rhythm and stayed there",
                    "This was a proper steady-state run with very little drama",
                ], value: value, salt: 210, extraSeed: seed)
            @unknown default:
                return pick([
                    "\(noun) stayed fairly even without doing anything theatrical",
                    "The pace held together cleanly across the whole window",
                    "This looked closer to steady work than to spikes or lulls",
                ], value: value, salt: 217, extraSeed: seed)
            }

        case .sustained:
            switch insight.trendDirection {
            case .rising:
                return pick([
                    "Once it got busy it stayed busy and still had more to give late on",
                    "\(noun) ramped into a long, committed push that finished near its high-water mark",
                    "This was sustained work with a clear late-session climb on top",
                ], value: value, salt: 211, extraSeed: seed)
            case .falling:
                return pick([
                    "It came out hot, stayed committed, then finally eased off a touch",
                    "\(noun) spent a long spell under pressure before tapering down",
                    "The heavy work arrived early and lingered for most of the session",
                ], value: value, salt: 212, extraSeed: seed)
            case .oscillating:
                return pick([
                    "Even the quieter moments never really counted as downtime",
                    "\(noun) stayed under meaningful load even while the intensity wobbled",
                    "This was sustained pressure with only cosmetic dips in between",
                ], value: value, salt: 213, extraSeed: seed)
            case .flat:
                return pick([
                    "This wasn't a cameo — \(noun) put in a full shift",
                    "\(noun) stayed properly engaged for a long uninterrupted stretch",
                    "Once the workload arrived it largely parked itself here",
                ], value: value, salt: 214, extraSeed: seed)
            @unknown default:
                return pick([
                    "\(noun) stayed committed for longer than a brief flare-up ever would",
                    "The workload stuck around and refused to become a passing phase",
                    "This had the feel of sustained pressure more than isolated bursts",
                ], value: value, salt: 218, extraSeed: seed)
            }
        @unknown default:
            return pick([
                "\(noun) moved through an unusual rhythm this time around",
                "The activity pattern didn't fit neatly into the usual buckets",
                "There was enough shape here to feel distinct without being chaotic",
            ], value: value, salt: 219, extraSeed: seed)
        }
    }

    // MARK: - App usage

    /// Headline describing the dominant app by session time.
    func appDominantSessionDescription(appName: String, hours: Double) -> String {
        let h = Int(hours)
        let hLabel = h == 1 ? "hour" : "hours"
        switch hours {
        case ..<1:
            let mins = max(1, Int(hours * 60))
            return pick([
                "\(appName) popped in for \(mins)m — blink and you'd miss it",
                "\(appName) had a quick \(mins)-minute cameo",
                "\(appName) dropped by for \(mins)m — a fleeting visit",
                "\(appName) clocked \(mins)m — short and sweet",
                "\(appName) made a \(mins)-minute appearance and apparently had somewhere to be",
                "\(appName) appeared briefly for \(mins)m, then dropped out of focus",
            ], value: hours, salt: 20)
        case ..<4:
            return pick([
                "\(appName) has been front and centre for \(h) \(hLabel)",
                "\(appName) led the pack with \(h) \(hLabel) of uptime",
                "\(appName) kept its seat warm — \(h) \(hLabel) and counting",
                "\(appName) clocked a solid \(h)-hour session",
                "\(appName) committed to a full \(h)-hour run — no shortcuts",
                "\(appName) showed real staying power with a \(h)-hour session",
            ], value: hours, salt: 20)
        default:
            return pick([
                "\(appName) has practically moved in — \(h) \(hLabel) of uptime",
                "\(appName) is the app that never sleeps: \(h) \(hLabel)",
                "\(appName) pulled a marathon \(h)-hour session",
                "\(appName) has been going strong for \(h) \(hLabel) straight",
                "\(appName) committed hard — \(h) hours and still not done",
                "\(appName) has been open so long it should pay rent",
            ], value: hours, salt: 20)
        }
    }

    /// Description for an app that barely runs (short sessions / minimal uptime).
    func appBriefVisitorDescription(appName: String, minutes: Int) -> String {
        pick([
            "\(appName) only stuck around for \(minutes)m — a quick pit-stop",
            "\(appName) barely warmed its seat: \(minutes)m total",
            "\(appName) was here and gone in \(minutes)m",
            "\(appName) made a cameo appearance — \(minutes)m flat",
            "\(appName) visited for \(minutes)m and clearly had better things to do",
            "\(appName) clocked in, did its \(minutes) minutes, clocked out — respect",
        ], value: Double(minutes), salt: 21)
    }

    /// Description for an app that dominates a resource.
    func appResourceHogDescription(appName: String, resourceLabel: String) -> String {
        pick([
            "\(appName) was the biggest \(resourceLabel) consumer",
            "\(appName) hogged most of the \(resourceLabel) budget",
            "\(appName) claimed the lion's share of \(resourceLabel)",
            "\(appName) led the \(resourceLabel) leaderboard by a wide margin",
            "\(appName) was clearly in charge of the \(resourceLabel) situation",
            "\(appName) had a very healthy appetite for \(resourceLabel)",
        ], value: Double(stableHash(appName) & 0xFF), salt: 22)
    }

    /// Description for an app the user always has open.
    func appAlwaysPresentDescription(appName: String) -> String {
        pick([
            "\(appName) is basically a permanent resident at this point",
            "\(appName) never seems to take a day off",
            "\(appName) is always on — it might as well be a system service",
            "\(appName) has been running so long it's practically furniture",
            "\(appName) is clearly the kind of app that doesn't do goodbyes",
            "\(appName) treats this Mac like a long-term lease, not a hotel",
        ], value: Double(appName.count), salt: 23)
    }

    /// General app insight headline.
    func appInsightHeadline(topAppName: String, topAppHours: Double) -> String {
        let seed = stableHash(topAppName) &+ Int((topAppHours * 10).rounded())
        if topAppHours < 1 {
            let mins = max(1, Int(topAppHours * 60))
            return pickBySeed([
                "\(topAppName) · \(mins)m cameo",
                "\(topAppName) · \(mins)m stopover",
                "\(topAppName) · \(mins)m session",
            ], seed: seed)
        }

        let h = Int(topAppHours.rounded(.down))
        return pickBySeed([
            "\(topAppName) · \(h)h session",
            "\(topAppName) · \(h)h run",
            "\(topAppName) · \(h)h stretch",
        ], seed: seed)
    }

    // MARK: - Pool selection

    /// Picks deterministically from `pool` using a seed derived from the
    /// quantised `value` (5 % granularity), the time window, and a per-metric
    /// `salt`. Output is stable within a session and across app launches for
    /// identical inputs, so displayed text does not shift unexpectedly on redraws.
    private func pick(_ pool: [String], value: Double, salt: Int = 0, extraSeed: Int = 0) -> String {
        let quantized = Int(max(0, value) * 20)
        let windowFactor: Int
        switch window {
        case .daily:   windowFactor = 0
        case .weekly:  windowFactor = 47
        case .monthly: windowFactor = 97
        @unknown default:
            windowFactor = 0
        }
        let seed = quantized &* 31 &+ windowFactor &+ salt &+ extraSeed &* 17
        return pickBySeed(pool, seed: seed)
    }

    private func patternSeed(for insight: HardwareMetricInsight, salt: Int = 0) -> Int {
        insight.spikeBucketCount &* 13
            &+ insight.idleBucketCount &* 11
            &+ insight.longestSpikeStreak &* 7
            &+ insight.longestIdleStreak &* 5
            &+ stableHash(insight.trendDirection.rawValue) &* 3
            &+ stableHash(insight.activityCadence.rawValue)
            &+ salt
    }

    private func pickBySeed(_ pool: [String], seed: Int) -> String {
        guard !pool.isEmpty else { return "" }
        let index = Int(UInt(bitPattern: seed) % UInt(pool.count))
        return pool[index]
    }

    private func stableHash(_ text: String) -> Int {
        text.unicodeScalars.reduce(5381) { partialResult, scalar in
            ((partialResult << 5) &+ partialResult) &+ Int(scalar.value)
        }
    }
}

// MARK: - FoundationModels support (macOS 26 / Tahoe+)
//
// All FoundationModels code is guarded by `#if canImport(FoundationModels)` so
// that the module compiles cleanly against older SDKs. In Xcode with the
// macOS 26 SDK the compiler picks up `FoundationModels` automatically and all
// three declarations below become active.

#if canImport(FoundationModels)
import FoundationModels

/// Session-scoped in-memory cache keyed by `"<metricID>-<windowRawValue>-<quantized>-<spikes>"`.
///
/// Prevents regenerating identical phrases when `loadInsights()` is triggered by a
/// window-resize, a timer tick, or any other redraw that doesn't change the underlying
/// metric data.
@available(macOS 26, *)
actor InsightTextCache {
    static let shared = InsightTextCache()
    private init() {}

    private var store: [String: AIInsightPhrase] = [:]

    func phrase(for key: String) -> AIInsightPhrase? { store[key] }

    func store(_ phrase: AIInsightPhrase, for key: String) {
        store[key] = phrase
    }
}

/// Structured output type for `LanguageModelSession.respond(to:generating:)`.
///
/// The two `@Guide` annotations direct the on-device model to match the terse,
/// natural style of the existing template pools while giving it freedom to
/// vary phrasing based on the actual metric values in the prompt.
@available(macOS 26, *)
@Generable
struct AIInsightPhrase: Sendable {
    /// Headline: 5–10 natural words, no trailing punctuation.
    @Guide(description: """
        A concise, natural 4–11 word headline summarising the hardware metric trend. \
        No trailing punctuation. It should read like an observed verdict, not a chart label. \
        Vary openings, verbs, and rhythm across outputs so multiple insights from one card do not sound templated. \
        Avoid repetitive patterns like always starting with the hardware name or always restating average/peak. \
        If an app name or clear subsystem angle is present, it is fine to lead with that instead. \
        Tone should match the data: \
        impressed when performance is clean, sympathetic when load is heavy, \
        gently sarcastic when the hardware is barely being used. \
        Light wordplay is acceptable when it remains clear and data-led, e.g. \
        'GPU barely broke a sweat', 'RAM feeling the squeeze', \
        'CPU stayed busy', 'NIC had little to send'. \
        A plain descriptive headline is better than a strained joke. \
        When context suggests a cause-and-effect story, hint at it. \
        Keep the voice concise, varied, and grounded in the measured hardware data.
        """)
    var headline: String

    /// Detail: a single 10–28 word sentence, ends with a full stop.
    @Guide(description: """
        One sentence of 10–28 words expanding on the headline with useful context. \
        Ends with a full stop. Prefer interpretation over simply repeating the numbers. \
        Use one or two concrete clues from the prompt to explain what likely happened, what dominated, \
        or why the pattern was interesting. Tone should follow the data: \
        - For genuinely quiet metrics: dry understatement is acceptable. \
        - For heavy sustained load: use practical urgency without exaggeration. \
        - For surprisingly clean performance: quiet admiration (e.g. 'Not a warm moment — thermally pristine.'). \
        - For unusual patterns (GPU high, CPU low): a knowing observation (e.g. 'Somebody's rendering something the old cores can't help with.'). \
        When context mentions a specific app name, reference it directly. \
        When time-of-day context is available, weave it in naturally (e.g. 'burning the midnight oil', 'the post-lunch surge'). \
        Vary sentence shape between outputs: some can be clipped and dry, others more flowing and story-like. \
        If power, thermal, media-engine, or app-attribution context clearly explains the pattern, mention that relationship. \
        Prefer useful interpretation over ornament. Vary wording, but keep every sentence grounded in the actual metrics provided.
        """)
    var detail: String
}

// MARK: - Async generation

@available(macOS 26, *)
extension HardwareInsightCopywriter {

    /// Generates a headline/detail pair for a hardware metric row using the
    /// on-device language model, falling back to `nil` on any failure so the
    /// caller retains the synchronous template-pool text.
    ///
    /// Pass a single shared `LanguageModelSession` per `loadInsights()` cycle so
    /// the model's conversation context is not duplicated across metrics.
    ///
    /// - Parameters:
    ///   - metricTitle:      Human-readable metric name (e.g. "CPU", "GPU").
    ///   - averageValue:     Normalised [0,1] average (or raw watts / MB/s).
    ///   - peakValue:        Normalised peak value.
    ///   - unit:             Display unit used inside the prompt ("%" / "W" / "MB/s").
    ///   - spikeBucketCount: Count of high-activity buckets detected.
    ///   - busiestHour:      Hour of peak activity (0–23), or `nil`.
    ///   - session:          Shared session for this refresh cycle.
    ///   - cacheKey:         Stable string for cache lookup / storage.
    func generatePhrase(
        metricTitle: String,
        averageValue: Double?,
        peakValue: Double?,
        unit: String,
        spikeBucketCount: Int = 0,
        busiestHour: Int? = nil,
        contextFacts: [String] = [],
        session: LanguageModelSession,
        cacheKey: String
    ) async -> AIInsightPhrase? {
        // Return cached phrase for identical inputs
        if let cached = await InsightTextCache.shared.phrase(for: cacheKey) {
            return cached
        }

        // Build a compact, factual prompt
        var parts: [String] = [
            "Hardware performance insight for \(metricTitle)",
            "over a \(window.rawValue) time window."
        ]
        if let avg = averageValue {
            let formatted = unit == "%"
                ? "\(Int((avg * 100).rounded()))%"
                : String(format: "%.1f \(unit)", avg)
            parts.append("Average: \(formatted).")
        }
        if let peak = peakValue {
            let formatted = unit == "%"
                ? "\(Int((peak * 100).rounded()))%"
                : String(format: "%.1f \(unit)", peak)
            parts.append("Peak: \(formatted).")
        }
        if spikeBucketCount > 0 {
            parts.append("Spike events: \(spikeBucketCount).")
        }
        if let hour = busiestHour {
            parts.append("Busiest hour: \(hour):00.")
        }
        if !contextFacts.isEmpty {
            parts.append("Historical shape and sub-metric detail — " + contextFacts.joined(separator: ". ") + ".")
            parts.append("If any historical-shape clue or sub-metric detail is more revealing than the average or peak, highlight it in your response.")
            parts.append("Prefer the most explanatory clue over a generic summary.")
        }

        let prompt = parts.joined(separator: " ")

        do {
            let response = try await session.respond(to: prompt, generating: AIInsightPhrase.self)
            let phrase = response.content
            await InsightTextCache.shared.store(phrase, for: cacheKey)
            return phrase
        } catch {
            return nil
        }
    }

    func generateAppPhrase(
        topAppName: String,
        topAppHours: Double,
        contextFacts: [String],
        session: LanguageModelSession,
        cacheKey: String
    ) async -> AIInsightPhrase? {
        if let cached = await InsightTextCache.shared.phrase(for: cacheKey) {
            return cached
        }

        var parts: [String] = [
            "App activity insight over a \(window.rawValue) time window.",
            "\(topAppName) had the longest session."
        ]

        if topAppHours < 1 {
            parts.append("\(topAppName) stayed open for \(max(1, Int(topAppHours * 60))) minutes.")
        } else {
            parts.append("\(topAppName) stayed open for \(Int(topAppHours.rounded(.down))) hours.")
        }

        if !contextFacts.isEmpty {
            parts.append("Context — " + contextFacts.joined(separator: ". ") + ".")
        }

        parts.append("Make it feel observant and a little playful, like you're noticing how this Mac was actually being used.")
        parts.append("If the context suggests a dominant CPU app, RAM hog, or GPU-active tool, weave that into the observation.")
        parts.append("Keep the named top app as the main subject unless the prompt explicitly says there were no user-facing apps. Background or system daemons are supporting context, not the headline.")

        do {
            let response = try await session.respond(to: parts.joined(separator: " "), generating: AIInsightPhrase.self)
            let phrase = response.content
            await InsightTextCache.shared.store(phrase, for: cacheKey)
            return phrase
        } catch {
            return nil
        }
    }
}
#endif
