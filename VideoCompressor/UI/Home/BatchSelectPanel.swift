import SwiftUI

/// 一键选择面板：选择本次批量任务的候选视频数量。
/// 滑块 10–200 步进 5；另有「全部」选项。面板显示真实统计：
/// 扫描总数 / 候选数 / 预计跳过数（阈值规则）/ 实际准备压缩数。
struct BatchSelectPanel: View {
    let totalScanned: Int
    let thresholdEnabled: Bool
    let thresholdMB: Double
    /// 首页按当前排序预计算的「候选中低于阈值数量」（无法确定大小的不计入）
    let skipEstimate: (Int, Int) -> Int
    let onApply: (Int?, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var count: Double = 20
    @State private var selectAll = false

    /// 候选数量（受总数限制，不越界）。
    private var candidateCount: Int {
        selectAll ? totalScanned : min(Int(count), totalScanned)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("扫描到的视频").font(.subheadline).foregroundStyle(.secondary)
                    Text("\(totalScanned) 个").font(.title2.bold())
                }

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("选择全部（\(totalScanned) 个）", isOn: $selectAll)
                    if selectAll {
                        Text("「全部」= 纳入所有可访问的视频，不受滑块上限限制。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("本次候选数量").font(.subheadline)
                            Spacer()
                            Text("\(candidateCount) 个")
                                .font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
                        }
                        Slider(value: $count, in: 10...200, step: 5)
                        HStack {
                            Text("10").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text("步进 5").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text("200").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if totalScanned < 10 {
                            Text("当前仅扫描到 \(totalScanned) 个视频，少于滑块最小值，将全部纳入。")
                                .font(.caption).foregroundStyle(.orange)
                        } else if totalScanned < Int(count) {
                            Text("扫描到的视频只有 \(totalScanned) 个，实际按 \(totalScanned) 个计算。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }

                // 真实统计（按当前排序与阈值动态计算）
                let skipped = skipEstimate(candidateCount)
                VStack(alignment: .leading, spacing: 4) {
                    statLine("候选视频", "\(candidateCount) 个")
                    statLine("预计自动跳过", thresholdEnabled ? "\(skipped) 个" : "0 个（规则未开启）")
                    statLine("实际准备压缩", "\(max(candidateCount - skipped, 0)) 个")
                    if thresholdEnabled {
                        Text("跳过规则：文件大小严格小于 \(Int(thresholdMB)) MB；等于阈值照常压缩；大小未知不会被跳过。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Spacer()
            }
            .padding(20)
            .navigationTitle("一键选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入队列") {
                        onApply(selectAll ? nil : Int(count), selectAll)
                        dismiss()
                    }
                    .disabled(totalScanned == 0)
                }
            }
        }
    }

    private func statLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}
