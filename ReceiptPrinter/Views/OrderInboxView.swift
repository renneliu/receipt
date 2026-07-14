import SwiftUI

struct OrderInboxView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: OrderStatus = .pending
    @State private var selectedOrder: PendingOrder?

    private var filtered: [PendingOrder] {
        appState.orders.filter { $0.status == selectedTab }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView("暂无\(selectedTab.displayName)订单", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: $selectedOrder) { order in
                    Button { selectedOrder = order } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(order.displayTitle).font(.headline)
                            Text("\(order.cinemaName) · \(order.ruleName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(order.receivedAt.formatted())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("订单收件箱")
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("状态", selection: $selectedTab) {
                ForEach(OrderStatus.allCases) { status in
                    Text(status.displayName).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(item: $selectedOrder) { order in
            OrderDetailView(order: order)
                .environmentObject(appState)
                .frame(width: 920, height: 640)
        }
    }
}
