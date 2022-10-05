//
// Copyright (c) 2022 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    import CDarwinOperatingSystemStats
    import Darwin
    import Dispatch

    public class OperatingSystemStatsProducer {
        var nsPerMachTick: Double
        var nsPerSchedulerTick: Int

        var lock: pthread_mutex_t = .init()
        var condition: pthread_cond_t = .init()
        var peakThreads: Int = 0
        var peakThreadsRunning: Int = 0
        var runState: RunState = .running
        var sampleRate: Int = 10_000

        enum RunState {
            case running
            case shuttingDown
            case done
        }

        internal
        class CallbackDataCarrier<T> {
            init(_ data: T) {
                self.data = data
            }

            var data: T
        }

        init() {
            var info = mach_timebase_info_data_t()

            mach_timebase_info(&info)

            nsPerMachTick = Double(info.numer) / Double(info.denom)

            let schedulerTicksPerSecond = sysconf(_SC_CLK_TCK)

            nsPerSchedulerTick = 1_000_000_000 / schedulerTicksPerSecond

            pthread_mutex_init(&lock, nil)
            pthread_cond_init(&condition, nil)
        }

        fileprivate
        func getProcInfo() -> proc_taskinfo {
            var procTaskInfo = proc_taskinfo()
            let procTaskInfoSize = MemoryLayout<proc_taskinfo>.size

            let result = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &procTaskInfo, Int32(procTaskInfoSize))

            if result != procTaskInfoSize {
                fatalError("proc_pidinfo returned an error \(errno)")
            }
            return procTaskInfo
        }

        func startSampling(_: Int = 10_000) { // sample rate in microseconds
            DispatchQueue.global(qos: .userInitiated).async {
                pthread_mutex_lock(&self.lock)
                let rate = self.sampleRate
                self.peakThreads = 0
                self.peakThreadsRunning = 0
                self.runState = .running
                pthread_mutex_unlock(&self.lock)

                while true {
                    let procTaskInfo = self.getProcInfo()

                    pthread_mutex_lock(&self.lock)

                    if procTaskInfo.pti_threadnum > self.peakThreads {
                        self.peakThreads = Int(procTaskInfo.pti_threadnum)
                    }

                    if procTaskInfo.pti_numrunning > self.peakThreadsRunning {
                        self.peakThreadsRunning = Int(procTaskInfo.pti_numrunning)
                    }

                    if self.runState == .shuttingDown {
                        self.runState = .done
                        pthread_cond_signal(&self.condition)
                    }

                    let quit = self.runState

                    pthread_mutex_unlock(&self.lock)

                    if quit == .done {
                        return
                    }

                    usleep(UInt32.random(in: UInt32(Double(rate) * 0.9) ... UInt32(Double(rate) * 1.1)))
                }
            }
            // We'll sleep just a little bit to let the sampler thread get going so we don't get 0 samples
            usleep(1_000)
        }

        func stopSampling() {
            pthread_mutex_lock(&lock)
            runState = .shuttingDown

            while pthread_cond_wait(&condition, &lock) == 0 {
                if runState == .done {
                    pthread_mutex_unlock(&lock)
                    return
                }
            }
        }

        func makeOperatingSystemStats() -> OperatingSystemStats {
            let procTaskInfo = getProcInfo()
            let userTime = Int(nsPerMachTick * Double(procTaskInfo.pti_total_user))
            let systemTime = Int(nsPerMachTick * Double(procTaskInfo.pti_total_system))
            let totalTime = userTime + systemTime

            pthread_mutex_lock(&lock)
            let threads = peakThreads
            let threadsRunning = peakThreadsRunning
            pthread_mutex_unlock(&lock)

            let stats = OperatingSystemStats(cpuUser: userTime,
                                             cpuSystem: systemTime,
                                             cpuTotal: totalTime,
                                             peakMemoryResident: Int(procTaskInfo.pti_resident_size),
                                             peakMemoryVirtual: Int(procTaskInfo.pti_virtual_size),
                                             syscalls: Int(procTaskInfo.pti_syscalls_unix) +
                                                 Int(procTaskInfo.pti_syscalls_mach),
                                             contextSwitches: Int(procTaskInfo.pti_csw),
                                             threads: threads,
                                             threadsRunning: threadsRunning,
                                             readSyscalls: 0,
                                             writeSyscalls: 0,
                                             readBytesLogical: 0,
                                             writeBytesLogical: 0,
                                             readBytesPhysical: 0,
                                             writeBytesPhysical: 0)

            return stats
        }

        func metricSupported(_ metric: BenchmarkMetric) -> Bool {
            switch metric {
            case .readSyscalls:
                return false
            case .writeSyscalls:
                return false
            case .readBytesLogical:
                return false
            case .writeBytesLogical:
                return false
            case .readBytesPhysical:
                return false
            case .writeBytesPhysical:
                return false
            default:
                return true
            }
        }
    }

#endif