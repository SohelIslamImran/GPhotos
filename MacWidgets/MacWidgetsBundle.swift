import SwiftUI
import WidgetKit

@main
struct MacWidgetsBundle: WidgetBundle {
  var body: some Widget {
    MemoriesWidget()
    PeopleWidget()
    BackupStatusWidget()
  }
}
