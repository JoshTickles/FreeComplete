import Foundation

let externalPower = PowerEnvironment(onBattery: false, lowPowerMode: false)
let battery = PowerEnvironment(onBattery: true, lowPowerMode: false)
let lowPowerOnAC = PowerEnvironment(onBattery: false, lowPowerMode: true)
let unknown = PowerEnvironment(onBattery: nil, lowPowerMode: false)

for environment in [externalPower, battery, lowPowerOnAC, unknown] {
    let performance = PowerPolicy.resolve(mode: .performance, environment: environment)
    precondition(!performance.savesEnergy && performance.preloadsModel && performance.prefetchesContinuation,
                 "An explicit Performance override must retain proactive work regardless of the power source")
    precondition(performance.idleUnloadDelay == nil,
                 "Performance must not unload a model that it promises to keep ready")

    let saver = PowerPolicy.resolve(mode: .batterySaver, environment: environment)
    precondition(saver.savesEnergy && !saver.preloadsModel && !saver.prefetchesContinuation,
                 "An explicit Battery Saver override must prevent speculative work even on AC")
    precondition(saver.debounce > performance.debounce && saver.idleUnloadDelay == .seconds(60),
                 "Saver must coalesce typing bursts and eventually release idle model resources")
}

let automaticAC = PowerPolicy.resolve(mode: .automatic, environment: externalPower)
let automaticBattery = PowerPolicy.resolve(mode: .automatic, environment: battery)
let automaticLowPower = PowerPolicy.resolve(mode: .automatic, environment: lowPowerOnAC)
let automaticUnknown = PowerPolicy.resolve(mode: .automatic, environment: unknown)
precondition(!automaticAC.savesEnergy && automaticAC.preloadsModel && automaticAC.prefetchesContinuation,
             "Automatic must restore proactive work when connected to external power")
precondition(automaticBattery.savesEnergy && !automaticBattery.preloadsModel && !automaticBattery.prefetchesContinuation,
             "Unplugging must disable advance loading and next-continuation generation")
precondition(automaticLowPower.savesEnergy,
             "Low Power Mode must select saver even while plugged in")
precondition(automaticUnknown.savesEnergy && automaticUnknown.description.contains("unavailable"),
             "Unknown source must be disclosed, not misrepresented as external power")
precondition(automaticBattery.description != automaticLowPower.description,
             "Automatic must explain whether the source or Low Power Mode caused the change")
precondition(PowerPolicy.resolve(mode: .automatic, environment: externalPower) == automaticAC,
             "Returning from battery or Low Power Mode must restore the AC policy without a restart")
print("Power policy behavior checks passed")
