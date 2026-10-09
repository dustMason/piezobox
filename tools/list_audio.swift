import Foundation
import CoreAudio
func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
    var value:Unmanaged<CFString>?, size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id,&a,0,nil,&size,&value)==0, let result=value?.takeRetainedValue() else{return ""}
    return result as String
}
var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
var size:UInt32=0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size)
var ids=[AudioDeviceID](repeating:0,count:Int(size)/4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&ids)
var results:[[String:Any]]=[]
for id in ids {
    let name=string(id,kAudioObjectPropertyName), uid=string(id,kAudioDevicePropertyDeviceUID)
    if !CommandLine.arguments.contains("--all") && !name.contains("Piezo") && !uid.contains("Piezo") {continue}
    a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyNominalSampleRate,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
    var rate:Float64=0;size=8;AudioObjectGetPropertyData(id,&a,0,nil,&size,&rate)
    a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreamConfiguration,mScope:kAudioObjectPropertyScopeInput,mElement:0)
    size=0;AudioObjectGetPropertyDataSize(id,&a,0,nil,&size)
    let raw=UnsafeMutableRawPointer.allocate(byteCount:max(8,Int(size)),alignment:8);defer{raw.deallocate()}
    var channels=0
    if AudioObjectGetPropertyData(id,&a,0,nil,&size,raw)==0 {
        for b in UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to:AudioBufferList.self)){channels+=Int(b.mNumberChannels)}
    }
    results.append(["id":id,"name":name,"uid":uid,"rate":rate,"inputChannels":channels])
}
let data=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
print(String(data:data,encoding:.utf8)!)
