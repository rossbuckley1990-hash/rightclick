import Foundation
@main struct ExecutionRetentionPressure {
 static func main() throws {
  let store = ExecutionStore.shared
  let large = String(repeating:"evidence-",count:30000)
  let largeCount = 100
  for index in 0..<largeCount {
   store.put(ExecutionRecord(executionId:"large-\(index)",actionId:"pressure.large",state:.succeeded,
    message:"Completed controlled pressure record", output:large, events:[large],
    evidence:OutcomeEvidence(type:"actual-large-evidence",boundary:large,outcomeVerified:true)))
  }
  var largeRetained=0; var bytes=0
  for index in 0..<largeCount {if let record=store.get("large-\(index)"){largeRetained += 1;bytes += try JSONEncoder().encode(record).count}}
  let smallCount = 1100
  for index in 0..<smallCount {store.put(ExecutionRecord(executionId:"small-\(index)",actionId:"pressure.small",state:.accepted,message:"Provider accepted; not verified"))}
  var smallRetained=0
  for index in 0..<smallCount {if store.get("small-\(index)") != nil {smallRetained += 1}}
  let result:[String:Any] = ["largeSubmitted":largeCount,"largeRetained":largeRetained,"retainedLargeEncodedBytes":bytes,"smallSubmitted":smallCount,"smallRetained":smallRetained,"defaultCountCeiling":1024,"defaultEncodedByteCeiling":16777216,"countGreen":smallRetained<=1024,"byteGreen":bytes<=16777216]
  print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]),as:UTF8.self))
 }
}
