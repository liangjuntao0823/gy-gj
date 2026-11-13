import SwiftUI
import SwiftData

struct RentPlanDraft: Identifiable { let id: UUID; var date: Date; var amount: String; var isPaid: Bool }
struct UtilityPlanDraft: Identifiable { let id: UUID; var date: Date; var electric: String; var water: String; var balance: String; var settled: Bool; var statement: String }

struct RentPlanEditorView: View {
    let property: Property
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var drafts: [RentPlanDraft]
    init(property: Property) { self.property=property; let c=Calendar.current; _drafts=State(initialValue:property.monthlyRentRecords.map{RentPlanDraft(id:$0.id,date:c.date(from:DateComponents(year:$0.year,month:$0.month,day:property.rentDueDay)) ?? Date(),amount:String(Int($0.amount)),isPaid:$0.isPaid)}) }
    var body:some View{NavigationStack{List{ForEach($drafts){$d in VStack{WheelDateField(label:"收租日期",date:$d.date);HStack{TextField("金额",text:$d.amount).keyboardType(.decimalPad);Toggle("已收",isOn:$d.isPaid)}}}.onDelete{drafts.remove(atOffsets:$0)};Button{drafts.append(RentPlanDraft(id:UUID(),date:Date(),amount:String(Int(property.rent+property.prepayment)),isPaid:false))}label:{Label("新增收租计划",systemImage:"plus")}}.navigationTitle("编辑收租计划").navigationBarTitleDisplayMode(.inline).presentationDetents([.medium,.large]).toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){save()}}}}}
    /// v2.47：不再「先全删再新建」，改为按 id 复用已有记录、只删真正被移除的那些。
    /// 旧写法会让详情页/收租行手里的记录对象变成已删除对象，点勾时崩溃。
    private func save(){
        let c=Calendar.current
        let existing=property.monthlyRentRecords
        var byID:[UUID:RentMonthRecord]=[:]
        for r in existing{byID[r.id]=r}
        var used=Set<UUID>()
        var result:[RentMonthRecord]=[]
        for d in drafts.sorted(by:{$0.date<$1.date}){
            let y=c.component(.year,from:d.date),m=c.component(.month,from:d.date)
            let amount=Double(d.amount) ?? 0
            if let r=byID[d.id]{
                r.year=y;r.month=m;r.amount=amount;r.isPaid=d.isPaid
                r.paidDate = d.isPaid ? (r.paidDate ?? Date()) : nil
                used.insert(d.id);result.append(r)
            }else{
                let r=RentMonthRecord(id:d.id,year:y,month:m,amount:amount,isPaid:d.isPaid)
                r.paidDate = d.isPaid ? Date() : nil
                modelContext.insert(r);result.append(r)
            }
        }
        property.monthlyRentRecords=result
        for old in existing where !used.contains(old.id){modelContext.delete(old)}
        try? modelContext.save();dismiss()
    }
}

struct UtilityPlanEditorView: View {
    let property: Property
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var drafts:[UtilityPlanDraft]
    init(property:Property){self.property=property;_drafts=State(initialValue:property.utilitySettlementRecords.sorted{($0.dueDate ?? .distantFuture)<($1.dueDate ?? .distantFuture)}.map{UtilityPlanDraft(id:$0.id,date:$0.dueDate ?? Date(),electric:$0.electricAmount==0 ? "":String(Int($0.electricAmount)),water:$0.waterAmount==0 ? "":String(Int($0.waterAmount)),balance:$0.balance==0 ? "":String(Int($0.balance)),settled:$0.isSettled,statement:$0.statement)})}
    var body:some View{NavigationStack{List{ForEach($drafts){$d in VStack{WheelDateField(label:"结算日期",date:$d.date);HStack{TextField("电费",text:$d.electric).keyboardType(.numbersAndPunctuation);TextField("水费",text:$d.water).keyboardType(.numbersAndPunctuation)};HStack{TextField("结余",text:$d.balance).keyboardType(.numbersAndPunctuation);Toggle("已结算",isOn:$d.settled)};TextField("结算单",text:$d.statement,axis:.vertical).lineLimit(2...6)}}.onDelete{drafts.remove(atOffsets:$0)};Button{drafts.append(UtilityPlanDraft(id:UUID(),date:Date(),electric:"",water:"",balance:"",settled:false,statement:""))}label:{Label("新增水电计划",systemImage:"plus")}}.navigationTitle("编辑水电计划").navigationBarTitleDisplayMode(.inline).presentationDetents([.medium,.large]).toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){save()}}}}}
    /// v2.47：同样按 id 复用已有记录，只删被移除的那些，避免留下已删除对象
    private func save(){
        let c=Calendar.current
        let existing=property.utilitySettlementRecords
        var byID:[UUID:UtilitySettlementRecord]=[:]
        for r in existing{byID[r.id]=r}
        var used=Set<UUID>()
        var records:[UtilitySettlementRecord]=[]
        for d in drafts.sorted(by:{$0.date<$1.date}){
            let y=c.component(.year,from:d.date),m=c.component(.month,from:d.date)
            let period=property.utilitySettlementFrequency=="monthly" ? m:((m-1)/3+1)
            if let r=byID[d.id]{
                r.year=y;r.period=period;r.frequency=property.utilitySettlementFrequency
                r.electricAmount=Double(d.electric) ?? 0
                r.waterAmount=Double(d.water) ?? 0
                r.balance=Double(d.balance) ?? 0
                r.isSettled=d.settled;r.statement=d.statement
                r.settledAt = d.settled ? (r.settledAt ?? Date()) : nil
                r.dueDate=d.date
                used.insert(d.id);records.append(r)
            }else{
                let r=UtilitySettlementRecord(id:d.id,year:y,period:period,frequency:property.utilitySettlementFrequency,electricAmount:Double(d.electric) ?? 0,waterAmount:Double(d.water) ?? 0,balance:Double(d.balance) ?? 0,isSettled:d.settled,statement:d.statement,settledAt:d.settled ? Date():nil,dueDate:d.date)
                modelContext.insert(r);records.append(r)
            }
        }
        property.utilitySettlementRecords=records
        for old in existing where !used.contains(old.id){modelContext.delete(old)}
        try? modelContext.save();dismiss()
    }
}
