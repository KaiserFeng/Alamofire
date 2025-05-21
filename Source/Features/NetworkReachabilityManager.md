#  NetworkReachabilityManager

这是 Alamofire 的网络可达性管理器，用于监控网络连接状态。让我解释主要功能和使用方法：

1. **核心功能**:
```swift
class NetworkReachabilityManager {
    // 预定义实例，监控通用网络状态
    public static let `default` = NetworkReachabilityManager()
    
    // 网络状态
    public enum NetworkReachabilityStatus {
        case unknown           // 未知状态
        case notReachable     // 网络不可达
        case reachable(ConnectionType)  // 可达（WiFi或蜂窝）
    }
}
```

2. **主要属性**:
```swift
// 检查网络是否可达
var isReachable: Bool
// 检查是否通过蜂窝网络可达
var isReachableOnCellular: Bool
// 检查是否通过WiFi可达
var isReachableOnEthernetOrWiFi: Bool
// 当前网络状态
var status: NetworkReachabilityStatus
```

3. **使用示例**:
```swift
// 创建监听器
let manager = NetworkReachabilityManager.default

// 开始监听网络状态变化
manager?.startListening { status in
    switch status {
    case .reachable(.ethernetOrWiFi):
        print("WiFi连接")
    case .reachable(.cellular):
        print("蜂窝网络连接")
    case .notReachable:
        print("无网络连接")
    case .unknown:
        print("未知状态")
    }
}

// 停止监听
manager?.stopListening()
```

4. **主要用途**:
- 监控网络状态变化
- 判断网络连接类型
- 网络状态变化时执行回调
- 优化网络请求策略

这个管理器通常用于：
- 网络状态检测
- 离线模式处理
- 网络切换响应
- 网络质量监控

