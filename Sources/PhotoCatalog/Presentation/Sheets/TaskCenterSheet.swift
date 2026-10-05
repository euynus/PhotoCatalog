import SwiftUI

@MainActor
struct TaskCenterSheet: View {
    let tasks: [BackgroundTask]
    var persistenceError: String? = nil
    var actions: (BackgroundTask) -> BackgroundTask.Actions = { _ in .init() }
    var onClearFinished: (() -> Void)? = nil
    let onClose: () -> Void
    @State private var selectedID: UUID?

    private var orderedTasks: [BackgroundTask] { BackgroundTask.ordered(tasks) }
    private var selectedTask: BackgroundTask? { BackgroundTask.selected(in: tasks, id: selectedID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let persistenceError {
                Label(persistenceError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.redSoft)
                    .lineLimit(3).help(persistenceError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Divider()
            }
            if tasks.isEmpty {
                Label("暂无任务", systemImage: "list.bullet.rectangle")
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(orderedTasks) { task in
                            TaskRow(task: task).tag(task.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(width: 290)
                    .accessibilityLabel("任务列表")
                    Divider()
                    if let selectedTask {
                        TaskDetail(task: selectedTask, actions: selectedTask.availableActions(actions(selectedTask)))
                            .id(selectedTask.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Divider()
            HStack {
                Text("共 \(tasks.count) 个任务").font(.caption).foregroundStyle(Theme.text3)
                if let onClearFinished {
                    Button("清除已结束记录", systemImage: "trash", action: onClearFinished)
                        .disabled(!tasks.contains { !$0.state.isActive })
                        .help("清除已结束的任务记录")
                }
                Spacer()
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.bgSidebar)
        }
        .frame(width: 800, height: 560)
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
        .onAppear(perform: reconcileSelection)
        .onChange(of: tasks.map(\.id)) { reconcileSelection() }
        .onChange(of: selectedID) {
            if selectedID == nil { reconcileSelection() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("任务中心", systemImage: "list.bullet.rectangle")
                .font(.system(size: 17, weight: .semibold))
            HStack(spacing: 16) {
                Text("排队 \(tasks.filter { $0.state == .queued }.count)")
                Text("运行 \(tasks.filter { $0.state == .running }.count)")
                if tasks.contains(where: { $0.state == .paused }) {
                    Text("暂停 \(tasks.filter { $0.state == .paused }.count)")
                }
                Text("需关注 \(tasks.filter(\.needsAttention).count)")
                Text("部分失败 \(tasks.filter(\.hasPartialFailure).count)")
            }
            .font(.caption).monospacedDigit().foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheetHeaderBar(vertical: 12)
    }

    private func reconcileSelection() {
        selectedID = selectedTask?.id
    }

    private struct TaskRow: View {
        let task: BackgroundTask

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: task.statusSymbol)
                    .foregroundStyle(task.statusColor)
                    .frame(width: 16).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title).font(.callout.weight(.medium))
                        .lineLimit(1).help(task.title)
                    HStack {
                        Text(task.statusTitle)
                        Spacer(minLength: 4)
                        Text(task.createdAt, format: .dateTime.month().day().hour().minute())
                    }
                    .font(.caption).foregroundStyle(Theme.text2)
                    if task.state.isActive, let progress = task.fractionCompleted {
                        ProgressView(value: progress).progressViewStyle(.linear)
                            .accessibilityLabel("任务进度")
                    }
                }
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
    }

    private struct TaskDetail: View {
        let task: BackgroundTask
        let actions: BackgroundTask.Actions

        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(task.title).font(.headline).textSelection(.enabled)
                        Label(task.statusTitle, systemImage: task.statusSymbol)
                            .foregroundStyle(task.statusColor)
                        if !task.detail.isEmpty {
                            Text(task.detail).font(.callout).textSelection(.enabled)
                        }
                        if task.state.isActive || task.fractionCompleted != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: task.fractionCompleted).progressViewStyle(.linear)
                                    .tint(Theme.accent).accessibilityLabel("任务进度")
                                if let total = task.totalCount, total > 0 {
                                    Text("已处理 \(task.completedCount) / \(total)")
                                        .font(.caption).monospacedDigit().foregroundStyle(Theme.text2)
                                }
                            }
                        }
                        HStack(spacing: 24) {
                            count(task.succeededCount, title: L("成功", table: "Context"))
                            count(task.skippedCount, title: L("跳过", table: "Context"))
                            count(task.failureCount, title: L("失败"))
                        }
                        Divider()
                        metadata
                        if let error = task.errorMessage, !error.isEmpty {
                            Text(error).foregroundStyle(Theme.redSoft).textSelection(.enabled)
                        }
                        if task.failureCount > 0 { failureList }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }
                Divider()
                HStack(spacing: 10) {
                    if let cancel = actions.cancel {
                        Button(action: cancel) { Label(actions.cancelTitle, systemImage: "xmark.circle") }
                            .labelStyle(.iconOnly).help(actions.cancelTitle).accessibilityLabel(actions.cancelTitle)
                    }
                    if let pause = actions.pause {
                        Button("暂停任务", systemImage: "pause.circle", action: pause)
                            .labelStyle(.iconOnly).help("暂停任务").accessibilityLabel("暂停任务")
                    }
                    if let resume = actions.resume {
                        Button("继续任务", systemImage: "play.circle", action: resume)
                            .labelStyle(.iconOnly).help("继续任务").accessibilityLabel("继续任务")
                    }
                    if let retry = actions.retry {
                        Button(action: retry) { Label(actions.retryTitle, systemImage: "arrow.clockwise") }
                            .help(actions.retryTitle).accessibilityLabel(actions.retryTitle)
                    }
                    if let review = actions.review {
                        Button("审阅结果", systemImage: "doc.text.magnifyingglass", action: review)
                            .labelStyle(.iconOnly).help("审阅结果").accessibilityLabel("审阅结果")
                    }
                    if let selectFailures = actions.selectFailures {
                        Button("选择失败照片", systemImage: "photo.on.rectangle", action: selectFailures)
                            .labelStyle(.iconOnly).help("选择失败照片").accessibilityLabel("选择失败照片")
                    }
                    Spacer(minLength: 0)
                    if let reveal = actions.revealDestination {
                        Button("在 Finder 中显示", systemImage: "folder", action: reveal)
                            .labelStyle(.iconOnly).help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示")
                    }
                }
                .controlSize(.small)
                .frame(minHeight: 24)
                .padding(.horizontal, 18).padding(.vertical, 10)
            }
        }

        private var metadata: some View {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("创建时间", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let finishedAt = task.finishedAt {
                    LabeledContent("结束时间", value: finishedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let destination = task.destination, destination.isFileURL {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("目标位置").foregroundStyle(Theme.text2)
                        Text(destination.path).textSelection(.enabled)
                            .lineLimit(3).truncationMode(.middle).help(destination.path)
                    }
                }
            }
        }

        private func count(_ value: Int, title: String) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(value, format: .number).monospacedDigit().fontWeight(.semibold)
                Text(title).font(.caption).foregroundStyle(Theme.text2)
            }
        }

        private var failureList: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("失败项目").fontWeight(.semibold)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(task.failures) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.item).fontWeight(.medium)
                            Text(failure.message).foregroundStyle(Theme.text2)
                            if let path = failure.path {
                                Text(path).font(.caption).foregroundStyle(Theme.text3)
                                    .lineLimit(2).truncationMode(.middle).help(path)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
                if task.omittedFailureCount > 0 {
                    Text("另有 \(task.omittedFailureCount) 个失败项目未保留明细")
                        .font(.caption).foregroundStyle(Theme.text3)
                }
            }
        }
    }
}

private extension BackgroundTask {
    var statusTitle: String {
        switch state {
        case .queued: return L("排队中")
        case .running: return L("运行中")
        case .paused: return L("已暂停")
        case .completed:
            if failureCount > 0 { return hasPartialFailure ? L("部分失败") : L("失败") }
            return L("已完成")
        case .failed: return hasPartialFailure ? L("部分失败") : L("失败")
        case .cancelled: return L("已取消")
        case .interrupted: return L("已中断")
        }
    }

    var statusSymbol: String {
        if needsAttention { return "exclamationmark.triangle" }
        switch state {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed, .interrupted: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }

    var statusColor: Color {
        if needsAttention { return Theme.redSoft }
        switch state {
        case .running: return Theme.accent
        case .completed: return Theme.green
        default: return Theme.text2
        }
    }
}
