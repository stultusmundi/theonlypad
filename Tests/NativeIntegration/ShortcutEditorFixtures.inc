extension KeyboardShortcutController {
 var fixtureMinimumLayout:Bool {
  window!.setContentSize(NSSize(width:650,height:600));window!.contentView!.layoutSubtreeIfNeeded()
  return window!.contentView!.bounds.width <= 650.5 && buttons.values.filter{!$0.isHidden}.allSatisfy { button in
   let rect=button.convert(button.bounds,to:window!.contentView!)
   return button.frame.height >= 20 && button.frame.width > 0 && window!.contentView!.bounds.contains(rect) && button.frame.width + 0.5 >= button.fittingSize.width
  }
 }
 var fixtureMinimumHeightLayout:Bool {
  window!.setContentSize(NSSize(width:650,height:500));window!.contentView!.layoutSubtreeIfNeeded()
  return window!.contentView!.bounds.width <= 650.5 && window!.contentView!.bounds.height <= 500.5 && buttons.values.filter{!$0.isHidden}.allSatisfy { button in
   button.frame.height >= 20 && window!.contentView!.bounds.contains(button.convert(button.bounds,to:window!.contentView!))
  }
 }
 var fixtureStatusEndReachable:Bool {
  guard let layout=status.layoutManager,let container=status.textContainer,!status.string.isEmpty else{return false}
  let range=NSRange(location:(status.string as NSString).length-1,length:1)
  layout.ensureLayout(for:container);status.scrollRangeToVisible(range);layout.ensureLayout(for:container)
  let glyphs=layout.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
  let rect=layout.boundingRect(forGlyphRange:glyphs,in:container).offsetBy(dx:status.textContainerOrigin.x,dy:status.textContainerOrigin.y)
  return rect.height>0 && status.visibleRect.intersects(rect)
 }
 var fixtureDeclaredContentMinimum:Bool {window!.contentMinSize == NSSize(width:650,height:500)}
 var fixtureColumnsReachable:Bool {
  window!.setContentSize(NSSize(width:650,height:500));window!.contentView!.layoutSubtreeIfNeeded()
  guard let scroll=table.enclosingScrollView else{return false}
  let width=table.tableColumns.reduce(0){$0+$1.width}
  guard width <= scroll.contentSize.width || scroll.hasHorizontalScroller else{return false}
  table.scrollColumnToVisible(table.tableColumns.count-1)
  let last=table.rect(ofColumn:table.tableColumns.count-1)
  return last.width>0 && last.minX >= table.visibleRect.minX - 1 && last.maxX <= table.visibleRect.maxX + 1
 }
 var fixtureRecorderHidden:Bool {recorder.isHidden}
 var fixtureStatus:String {status.string}
 var fixtureRows:[String] {rows}
 var fixtureSelected:String? {selectedID}
 func fixtureEnabled(_ id:String)->Bool {buttons[id]?.isEnabled == true}
 func fixtureClick(_ id:String) {buttons[id]?.performClick(nil)}
 func fixtureSelect(_ id:String) {if let row=rows.firstIndex(of:id){table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}}
 func fixtureSearch(_ query:String) {search.stringValue=query;controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))}
}
