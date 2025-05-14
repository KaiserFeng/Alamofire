#  RequestTaskMap

`RequestTaskMap` 不仅仅提供简单的映射关系，它是一个复杂的任务管理器。让我解析其主要功能：

1. **双向一对一映射**:
```swift
private var tasksToRequests: [URLSessionTask: Request]
private var requestsToTasks: [Request: URLSessionTask]
```
- 维护 Request 和 URLSessionTask 的双向映射
- 确保一个 Request 只对应一个 Task，反之亦然

2. **任务事件跟踪**:
```swift
private typealias Events = (completed: Bool, metricsGathered: Bool)
private var taskEvents: [URLSessionTask: Events]
```
- 跟踪每个任务的完成状态
- 跟踪性能指标收集状态
- 管理任务生命周期

3. **一致性检查**:
```swift
var count: Int {
    precondition(tasksToRequests.count == requestsToTasks.count,
                 "RequestTaskMap.count invalid...")
    return tasksToRequests.count
}
```
- 严格保证映射的一致性
- 通过断言确保数据完整性

4. **智能解关联**:
```swift
mutating func disassociateIfNecessaryAfterGatheringMetricsForTask(_ task: URLSessionTask) -> Bool
mutating func disassociateIfNecessaryAfterCompletingTask(_ task: URLSessionTask) -> Bool
```
- 根据任务状态自动管理关联关系
- 处理不同平台的性能指标收集差异
- 防止内存泄漏

5. **安全的访问控制**:
```swift
subscript(_ request: Request) -> URLSessionTask?
subscript(_ task: URLSessionTask) -> Request?
```
- 提供安全的存取接口
- 自动维护内部状态一致性
- 处理nil值的清理工作

主要作用：
- 任务生命周期管理
- 内存管理
- 状态追踪
- 平台兼容性处理
- 数据一致性保证

这是一个核心的管理组件，而不仅仅是简单的映射关系。
