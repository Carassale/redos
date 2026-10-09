import Charts
import RedOSCore
import SwiftUI

/// Answer text with its chart, image, diagram and sources.
struct AnswerView: View {
    let answer: CommandPanelModel.Answer
    let onOpenDiagram: (Diagram) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: answer.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let chart = answer.chart {
                AnswerChart(chart: chart)
            }
            if let image = answer.image {
                AsyncImage(url: image) { phase in
                    if let picture = phase.image {
                        picture.resizable().scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                }
            }
            if let diagram = answer.diagram {
                Button("Open Diagram", systemImage: "rectangle.on.rectangle") { onOpenDiagram(diagram) }
            }
            if !answer.sources.isEmpty {
                Text("Sources: \(answer.sources.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AnswerChart: View {
    let chart: ChartSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !chart.title.isEmpty {
                Text(verbatim: chart.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(chart.series, id: \.name) { series in
                    ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                        switch chart.kind {
                        case .bar:
                            BarMark(x: .value("x", point.label), y: .value(chart.unit ?? "", point.value))
                                .foregroundStyle(by: .value("series", series.name))
                        case .line:
                            LineMark(x: .value("x", point.label), y: .value(chart.unit ?? "", point.value))
                                .foregroundStyle(by: .value("series", series.name))
                                .interpolationMethod(.catmullRom)
                            PointMark(x: .value("x", point.label), y: .value(chart.unit ?? "", point.value))
                                .foregroundStyle(by: .value("series", series.name))
                                .symbolSize(20)
                        }
                    }
                }
            }
            .chartLegend(chart.series.count > 1 ? .visible : .hidden)
            .chartYScale(domain: .automatic(includesZero: chart.kind == .bar))
            .frame(height: 150)
        }
    }
}
