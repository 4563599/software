# 编码规范

来源：[Kotlin 官方文档中文版：编码规范](https://book.kotlincn.net/text/coding-conventions.html)。核对日期：2026-10-20。
本文件按网页的章节名称、层级与顺序逐项整理，保留规则的适用条件、建议强度和例外；示例为对应规则的说明片段，并非逐字镜像。
技能自身的运行与兼容性策略另见 [额外执行说明](execution-guidance.md)，不混入以下规范。

## 在 IDE 中配置风格

IntelliJ IDEA 和 Android Studio 都支持按 Kotlin 风格自动格式化及检查代码。

### 应用风格指南

在 `Settings/Preferences | Editor | Code Style | Kotlin` 中，选择 `Set from...`，再选择 `Kotlin style guide`。

### 验证代码是否遵循风格指南

在 `Settings/Preferences | Editor | Inspections | General` 中启用 `Incorrect formatting`。命名等其他相关检查通常已默认开启。

## 源代码组织

### 目录结构

- 纯 Kotlin 项目的目录对应包层次，但可省略共同的根包。例如共同根包是 `com.example.app` 时，其直接成员放在源根目录，`com.example.app.network` 的文件放在 `network/`。
- JVM 项目中，Kotlin 与 Java 使用相同的源文件根目录及目录组织方式，每个文件的位置与其 `package` 相符。

### 源文件名称

- 文件只有一个主要类或接口及相关顶层声明时，文件名使用该类型名并加 `.kt`。
- 多个相关类或只有顶层声明时，以文件职责命名，采用 UpperCamelCase。
- 文件名应说明用途，避免以含义空泛的 `Util` 等词概括不同职责。

#### 多平台项目

平台源集中含顶层声明的文件名加平台后缀；公共源集的同类文件不加平台后缀。例如：

```text
commonMain/kotlin/DeviceInfo.kt
jvmMain/kotlin/DeviceInfo.jvm.kt
androidMain/kotlin/DeviceInfo.android.kt
iosMain/kotlin/DeviceInfo.ios.kt
```

##### 技术细节

- JVM 没有直接对应 Kotlin 顶层函数、属性的成员容器，Kotlin/JVM 编译器将这些声明放入根据文件名生成的文件门面类。
- 同包的公共源集与 JVM 源集若都使用 `DeviceInfo.kt` 且有顶层声明，可能生成相同完全限定名的 `DeviceInfoKt`，造成重复 JVM 类。
- 平台文件后缀用于区分这些门面类。即使非 JVM 平台没有此限制，或当前文件尚无顶层声明，也推荐保持该命名习惯，以便一致维护并防止后续新增顶层声明时冲突。

### 源文件组织

- 语义紧密相关的类、函数和属性可以同文件组织，文件保持合理规模，通常不超过几百行。
- 适用于一个类全部调用方的扩展函数靠近该类；仅服务某个调用方的扩展函数靠近该调用方。
- 不仅仅为了收集某类型的全部扩展函数而单独建立文件。

### 类布局

成员通常依次为：

1. 属性和初始化块。
2. 次构造函数。
3. 方法。
4. 伴生对象。

不要按字母或可见性排序方法，也不必把普通方法与扩展方法分成两组。相关方法放在一起，按一致的自顶向下或自底向上逻辑排列。
嵌套类靠近使用处；只供外部使用、当前类内部不用的嵌套类放在末尾的伴生对象之后。

### 接口实现布局

实现成员的顺序与接口声明顺序保持一致；需要的私有辅助方法可以插在相关实现附近。

### 重载布局

同一方法的重载放在一起。

## 命名规则

- 包名使用小写且不带下划线，如 `com.example.project`。避免不必要的多词名称；确有需要时可连写或采用文档允许的驼峰组合。
- 类与对象采用 UpperCamelCase，例如 `DeviceReader`、`DefaultDeviceReader`。

### 函数名

函数、普通属性、局部变量采用 lowerCamelCase，不使用下划线。用于创建实例的工厂函数是例外，可以与抽象返回类型同名：

```kotlin
interface DeviceClient
private class DefaultDeviceClient : DeviceClient
fun DeviceClient(): DeviceClient = DefaultDeviceClient()
```

### 测试方法的名称

仅在测试中允许使用反引号包围的空格方法名，测试方法也可以带下划线。Android 上运行带空格的方法名需要注意 API 30 及以上的运行时支持。

```kotlin
@Test fun `returns cached device`() { /* 测试体 */ }
@Test fun returnsCachedDevice_whenDisconnected() { /* 测试体 */ }
```

### 属性名

- `const` 属性，以及没有自定义 getter、保存不可变数据的顶层或对象 `val` 常量，采用 SCREAMING_SNAKE_CASE。
- 保存可变数据或带行为对象的顶层、对象属性采用 lowerCamelCase。
- 引用单例对象的属性允许采用与 `object` 声明相同的命名风格。
- 枚举条目可以用全大写下划线，也可以用 UpperCamelCase，按用途选择。

```kotlin
const val MAX_RETRY_COUNT = 3
val devicesById = mutableMapOf<String, String>()
val NameComparator: Comparator<String> = compareBy { it.length }
```

### 幕后属性的名称

公共 API 属性与内部实现属性表达同一个概念时，内部属性加 `_` 前缀：

```kotlin
private val _deviceNames = mutableListOf<String>()
val deviceNames: List<String>
    get() = _deviceNames
```

### 选择好名称

- 类名通常是说明“是什么”的名词或名词短语，方法名通常是说明“做什么”的动词或动词短语。
- 名称区分修改原对象与创建新结果，例如 `sort` 原地排序，`sorted` 返回排序结果。
- 避免无助于说明职责的 `Manager`、`Wrapper` 等空泛词语。
- 两字母缩写整体大写，例如 `IOStream`；更长缩写通常仅首字母大写，例如 `XmlFormatter`、`HttpInputStream`。

## 格式化

### 缩进

使用四个空格，不使用 Tab。通常左花括号接在起始行末尾，右花括号另起一行并与起始结构对齐。
Kotlin 的分号可省略，换行参与语法判定，因此不要随意换成另一套花括号风格。

```kotlin
if (connected) {
    for (device in devices) {
        render(device)
    }
}
```

### 横向空白

- 二元运算符两侧有空格，例如 `a + b`；区间运算符不加空格，例如 `0..lastIndex`。
- 一元运算符不加分隔空格，例如 `count++`。
- 控制流关键字与 `(` 之间有空格；构造函数、函数声明、函数调用名称与 `(` 之间没有空格。
- `(`、`[` 后以及 `)`、`]` 前不填空格。
- `.`、`?.`、`::` 两侧不填空格；可空标记紧接类型，如 `String?`。
- `//` 后有一个空格。
- 类型参数的尖括号与类型之间不填空格，如 `Map<Key, Value>`。
- 通常不横向补空格对齐多行声明或赋值；更改标识符长度不应引起周围行排版变化。

### 冒号

- 声明与类型之间，冒号前无空格，后有空格：`val name: String`。
- 类型继承、构造委托，以及 `object` 与父类型之间，冒号前后都有空格。

```kotlin
class DeviceScreen() : BaseScreen(), Runnable {
    constructor(name: String) : this()
    override fun run() {}
}
```

### 类头

- 短主构造函数可以同行；长参数列表每个参数独占一行、缩进四空格，右括号另起一行。
- 继承的父类调用或接口列表与构造函数右括号同一行；多个超类型先列父类，再逐行列接口。
- 超类型列表过长时，在冒号后换行，并对齐超类型。
- 很长的类头可通过类体前的空行或独立一行的左花括号与类体分隔；这是文档允许的特例。
- 构造参数使用常规四空格缩进，使构造属性与类内属性的缩进一致。

```kotlin
class DeviceScreen(
    deviceId: String,
    displayName: String,
) : BaseScreen(deviceId),
    Runnable {
    override fun run() {}
}
```

### 修饰符

多个修饰符按以下顺序选择需要的项；斜杠表示同组的选项，不是可直接复制的声明语法：

```text
public / protected / private / internal
expect / actual
final / open / abstract / sealed / const
external
override
lateinit
tailrec
vararg
suspend
inner
enum / annotation / fun
companion
inline / value
infix
operator
data
```

注解在修饰符前。除编写库等有明确 API 可见性要求的场合外，省略冗余的 `public` 等修饰符。

### 注解

注解一般与声明同缩进并独占一行。多个无参注解可以同行；单个无参注解也可以与短声明同行。

```kotlin
@Deprecated("Use the replacement")
fun oldQuery() {}

@Test fun returnsDefaultValue() {}
```

### 文件注解

文件注解位于文件注释之后、`package` 之前，并与 `package` 留空行。

```kotlin
/* 文件说明 */
@file:JvmName("DeviceQueries")

package example.devices
```

### 函数

长签名的参数逐行换行并缩进四空格。仅由一个表达式组成的函数体优先使用表达式体。

```kotlin
fun makeLabel(
    prefix: String,
    deviceId: String,
): String = "$prefix-$deviceId"
```

### 表达式函数体格式化

表达式函数体放不下一行时，`=` 保留在函数声明行，表达式换行并缩进四空格。

```kotlin
fun formatDeviceNames(names: List<String>) =
    names.filter { it.isNotBlank() }.joinToString(separator = ", ")
```

### 属性格式化

简单只读 getter 可使用单行形式；复杂 getter 与 setter 分行书写。长初始化表达式在 `=` 后换行并缩进四空格。

```kotlin
val isEmpty: Boolean get() = devices.isEmpty()

val description: String
    get() {
        return resolveDescription()
    }

private val deviceNames: List<String> =
    loadDeviceNamesFromStorage()
```

### 控制流语句

- 多行 `if` 或 `when` 条件使用花括号；条件续行缩进四空格，条件结束的 `)` 与 `{` 放在同一个独立行。
- `else`、`catch`、`finally` 以及 `do-while` 的 `while` 与前面的 `}` 同行。
- 多行 `when` 分支之间可留空行；短分支与条件同行，省略无必要的花括号。

```kotlin
if (isConnected &&
    isReady
) {
    queryDevice()
} else {
    showDisconnectedState()
}
```

### 方法调用格式化

长实参列表在左括号后换行，缩进四空格。关系紧密的参数可以分组同行。具名实参的 `=` 两侧留空格。

```kotlin
drawRectangle(
    x = 10, y = 20,
    width = 100, height = 80,
    filled = true,
)
```

### 链式调用换行

链式调用换行时将 `.` 或 `?.` 放在续行开头，按一级续行缩进；首次换行位置可以按表达清晰程度调整。

```kotlin
val labels = devices
    .filter { it.isAvailable }
    .map { it.name }
    .joinToString(separator = ", ")
```

### Lambda 表达式

- 花括号与参数箭头周围保持空格。接受单个 Lambda 时尽量使用尾随 Lambda。
- 显式标签紧接左花括号，例如 `scan@{`。
- 多行 Lambda 的参数放在首行，后接 `->` 与换行；参数列表太长时，箭头独占一行。

```kotlin
names.filter { it.isNotBlank() }

names.forEach visit@{ name ->
    println(name)
}

withEnvironment {
    context: Context,
    environment: Environment
    ->
    environment.configure(context)
}
```

### 尾部逗号

尾部逗号是列表最后一个元素后面的逗号。它减少增删、重排时的差异，也方便生成代码。
尾部逗号完全可选；文档鼓励在声明位置使用，调用位置是否使用可以自行决定。
在 IDE 的 `Editor | Code Style | Kotlin | Other` 中可启用 `Use trailing comma`。
以下保留网页列出的全部使用场景。

#### 枚举

最后一个枚举条目后可以有逗号：

```kotlin
enum class Direction {
    NORTH,
    SOUTH,
}
```

#### 值实参

普通函数调用及集合工厂调用的最后一个实参后可以有逗号：

```kotlin
queryDevice(
    deviceId,
    timeoutMs,
)
val labels = listOf(
    "Ready",
    "Offline",
)
```

#### 类属性与形参

主构造函数中，最后一个参数无论是否声明为属性，都可以加尾部逗号：

```kotlin
class DeviceLabel(
    val name: String,
    prefix: String,
)
```

#### 函数值形参

函数、构造函数及带 `vararg` 的参数声明都可以使用尾部逗号：

```kotlin
fun queryDevice(
    deviceId: String,
    timeoutMs: Long,
) {}

constructor(
    name: String,
    enabled: Boolean,
) {}

fun printValues(
    vararg values: Int,
    prefix: String,
) {}
```

#### 类型可选的形参（包括 setter）

在根据上下文推断参数类型的位置，参数列表也可有尾部逗号。匿名函数示例：

```kotlin
val sum: (Int, Int, Int) -> Int = fun(
    first,
    second,
    third,
): Int {
    return first + second + third
}
```

#### 索引后缀

多参数索引操作的最后一个实参后可以有逗号：

```kotlin
val value = surface[
    x,
    y,
]
```

#### lambda 表达式形参

最后一个 Lambda 形参后可以有逗号：

```kotlin
val printPair = {
    first: Int,
    second: Int,
    ->
    println("$first, $second")
}
```

#### when 条目

同一分支列举多个条件时，最后一个条件与箭头之间可以有尾部逗号：

```kotlin
when (type) {
    String::class,
    Int::class,
    -> true
    else -> false
}
```

#### （注解中的）集合字面值

注解中集合字面值的最后一个元素后可以有逗号：

```kotlin
annotation class SupportedNames(val names: Array<String>)

@SupportedNames([
    "Ready",
    "Offline",
])
fun renderState() {}
```

#### 类型实参

泛型调用的最后一个类型实参后可以有逗号：

```kotlin
val values = emptyMap<
    String,
    Int,
>()
```

#### 类型形参

泛型声明的最后一个类型形参后可以有逗号：

```kotlin
class Cache<
    Key,
    Value,
>
```

#### 解构声明

普通解构以及循环变量的解构都允许尾部逗号：

```kotlin
val (
    deviceId,
    name,
) = devicePair

for ((
    deviceId,
    name,
) in devicePairs) {
    println("$deviceId: $name")
}
```

## 文档注释

长 KDoc 的 `/**` 独占一行，后续行以 `*` 开头；短 KDoc 可以一行写完。
通常将参数与返回值说明融入正文，并用 `[parameterName]` 链接参数，而不是机械添加 `@param`、`@return`。较长且不适合正文的说明仍可以使用这些标签。

```kotlin
/**
 * 返回 [name] 去除首尾空白后的名称。
 */
fun normalizeName(name: String): String = name.trim()

/** 当前设备数量。 */
val count: Int get() = devices.size
```

## 避免重复结构

可选且被 IDE 判定为冗余的语法，通常应该省略，而不是为了表面明确保留重复结构。

### Unit 返回类型

函数返回 `Unit` 时省略显式返回类型：

```kotlin
fun refresh() {
    queryDevice()
}
```

### 分号

尽量不写可省略的分号。

### 字符串模版

简单变量使用 `$name`；只有复杂表达式才需要 `${...}`。

```kotlin
println("$name: ${devices.size}")
```

## 语言特性的惯用法

### 不可变性

- 优先不可变数据，初始化后不再重新赋值的局部变量与属性声明为 `val`。
- 不需要修改的集合通过 `Collection`、`List`、`Set`、`Map` 等接口表达。
- 创建无需修改的集合时，优先相应的集合工厂，而不是显式选择可变实现。

```kotlin
fun accepts(name: String, allowedNames: Set<String>): Boolean =
    name in allowedNames

val allowedNames = setOf("Ready", "Offline")
```

### 默认实参值

优先使用默认实参，而不是为默认值建立仅负责转发的重载。

```kotlin
fun makeLabel(prefix: String = "Device"): String = prefix
```

### 类型别名

重复使用的函数类型或参数化类型可以定义 `typealias`。若私有或内部别名只是解决名称冲突，优先使用导入别名。

```kotlin
typealias DeviceNames = Map<String, String>
typealias ResultHandler = (String) -> Unit
```

### Lambda 表达式参数

短且非嵌套的 Lambda 优先用 `it`；有参数的嵌套 Lambda 明确写出参数名。

```kotlin
groups.forEach { group ->
    group.devices.forEach { device ->
        render(device)
    }
}
```

### 在 lambda 表达式中返回

避免一个 Lambda 中有多个返回到标签的位置，优先考虑整理成单一退出点；若不清晰，可改为匿名函数。
Lambda 的最后一条语句不使用多余的标签返回，直接保留结果表达式。

```kotlin
val labels = names.map { name ->
    name.trim()
}
```

### 具名实参

多个同种基本类型参数或多个布尔参数可能难以理解时，使用具名实参；只有上下文中含义完全清楚时才可省略。

```kotlin
drawRectangle(x = 10, y = 20, width = 100, height = 80, filled = true)
```

### 条件语句

优先使用 `try`、`if`、`when` 的表达式形式，而不是在每个分支重复返回。

```kotlin
return if (connected) "Ready" else "Offline"

return when (state) {
    0 -> "Idle"
    1 -> "Charging"
    else -> "Unknown"
}
```

### if 还是 when

二选一通常用 `if`，三个或更多分支通常用 `when`。不要为了两个简单分支改成复杂的 `when`。

### Guard conditions in when expression

在带守卫条件的 `when` 中组合多个布尔表达式时，加括号表达该组合。

```kotlin
when (result) {
    is QueryResult.Ready if (result.info.isEmpty() || result.id == null) -> "No data"
    else -> "Other"
}
```

### 在条件中的可空的布尔值

可空 `Boolean` 条件用 `value == true` 或 `value == false` 明确判断。

```kotlin
if (enabled == true) {
    startQuery()
}
```

### 循环

- 优先考虑能清楚表达意图的 `filter`、`map` 等高阶函数。
- `forEach` 是例外：通常选择普通 `for`；接收者可空或已经属于较长调用链时，可以用 `forEach`。
- 比较复杂集合链与循环时，要考虑实际操作和性能开销。

### 区间上循环

左闭右开的索引范围使用 `..<`，而不是手动减去上界。

```kotlin
for (index in 0..<size) {
    process(index)
}
```

### 字符串

- 优先字符串模板，而不是字符串拼接。
- 多行文本优先多行字符串，而不是在普通字符串中反复插入 `\n`。
- 不需要保留内部缩进时用 `trimIndent`；需要保留内部缩进时，通过 `trimMargin` 指定边界。
- 注意 Java 与 Kotlin 多行字符串的区别，必要时查看原网页链接的对应专题。

```kotlin
val message = """
    Device is ready.
    Continue installation.
""".trimIndent()

val nested = """
    |Device:
    |    Ready
""".trimMargin()
```

### 函数还是属性

无参访问在以下条件同时成立时，优先考虑只读属性：不抛异常；计算成本很低或首次计算后缓存；对象状态不变时重复访问返回同一结果。

### 扩展函数

一个函数主要操作某个对象时，可以将该对象作为扩展接收者。通过局部扩展、成员扩展或私有顶层扩展等方式限制可见性，减少 API 污染。

### 中缀函数

`infix` 适合两个参与者角色相近的操作，例如 `and`、`to`、`zip`。改变接收者的方法不要声明为中缀函数，命令式的 `add` 不是良好用例。

### 工厂函数

工厂函数优先使用表达特殊创建方式的名称；没有额外语义时，才考虑与类型同名。
若多个构造函数无法合并为带默认参数的构造函数，且并非用于调用不同超类构造函数，可优先用工厂函数表达创建方式。

```kotlin
Point.fromPolar(angle, radius)
```

### 平台类型

- 公有函数或方法返回 Java 平台类型表达式时，显式声明 Kotlin 返回类型。
- 类级或包级属性由平台类型表达式初始化时，显式声明 Kotlin 类型。
- 同类表达式初始化的局部变量允许省略类型。

```kotlin
fun queryName(): String = JavaDeviceApi.getName()

val deviceName: String = JavaDeviceApi.getName()

fun printName() {
    val localName = JavaDeviceApi.getName()
    println(localName)
}
```

### 作用域函数 apply/with/run/also/let

Kotlin 提供 `let`、`run`、`with`、`apply`、`also`，用于在给定对象的上下文中执行代码。
具体选用方式参见原网页所链接的 [作用域函数](https://book.kotlincn.net/text/scope-functions.html) 专题。

## 库的编码规范

面向库与 SDK，为保持公有 API 稳定，额外遵循以下要求：

- 成员显式声明可见性，避免意外暴露。
- 函数返回类型与属性类型显式声明，避免实现调整悄悄改变 API 类型。
- 公有成员提供 KDoc；不需要新增文档的覆盖成员可以例外。

更多库 API 设计原则通过原网页末尾的“库作者指南”链接查阅。
