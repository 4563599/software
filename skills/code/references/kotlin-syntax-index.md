# Kotlin 语法 → 文档位置速查

文档：《Kotlin 官方文档 中文版》PDF（kotlincn-docs.pdf，2184 页）。页码是 PDF 的页码。
已切分的全文在 `references/kotlin-docs/`，表里没有的语法用下面的命令查：

```bash
node <技能目录>/scripts/kotlin-docs.js find <关键字...> [--chapter <章节名片段>] [--max 5]
```

写 `explain` 的语法项时，「语法名」尽量用文档里的叫法，「文档位置」照抄下表的「章节 › 小节 · 页码」。表里的「要点」是给写说明的人看的提示，正文请用自己的话写，不要大段照抄文档。

## 基础

| 语法 | 写法 | 文档位置 | 要点 |
|---|---|---|---|
| 变量（只读 / 可变） | `val` / `var` | 基本语法 › 变量 · 第 554-556 页 | val 只能赋值一次，var 可重新赋值；类型可推断 |
| 属性声明 | 类里的 `val` / `var` | 属性 › 声明属性 · 第 680-681 页 | val 只读（只有 getter），var 可变 |
| 编译期常量 | `const val` | 属性 › 编译期常量 · 第 683 页 | 只能在顶层、object 或伴生对象里，值必须是字符串或基本类型 |
| 延迟初始化属性 | `lateinit var` | 属性 › 延迟初始化属性与变量 · 第 683-684 页 | 非空类型，稍后再赋值 |
| 字符串模板 | `"$a"` / `"${表达式}"` | 基本语法 › 字符串模板 · 第 557-558 页 | 把变量或表达式的值拼进字符串 |
| 注释 | `//` / `/* */` / `/** */` | 基本语法 › 注释 · 第 557 页 | 行注释、块注释、文档注释 |
| 数值字面值 | `3000L` | 基本类型 › 数字（数值常量字面值） · 第 607 页 | L 结尾表示 Long |
| 显式数字转换 | `.toLong()` / `.toInt()` | 基本类型 › 显式数字转换 · 第 608 页 | 数字类型之间不会隐式转换，要调用 toXxx() |
| 属性的 getter / setter | `a.text = x` | 属性 › Getter 与 Setter · 第 680-682 页 | 读写属性实际调用 getter / setter，相当于 Java 的 getXxx()/setXxx() |
| 布尔运算 | `&&` / `\|\|` / `!` | 基本类型 › 布尔 · 第 616 页 | 与、或、非；&& 和 \|\| 是短路求值 |
| 相等性 | `==` / `!=` / `===` | 相等性 · 第 813-814 页 | == 比较内容（调用 equals），=== 比较是否同一个对象 |
| 索引访问 | `a[i]` | 操作符重载 › 索引访问操作符 · 第 785 页 | 等同于 a.get(i) / a.set(i, b) |
| 类型检测与智能转换 | `is` / `!is` | 类型检测与类型转换 › 智能转换 · 第 633-637 页 | 判断过类型后编译器自动转换 |

## 空安全

| 语法 | 写法 | 文档位置 | 要点 |
|---|---|---|---|
| 可空类型 | `String?` | 空安全 › 可空类型与非空类型 · 第 803-804 页 | 默认不能为 null，加 ? 才允许 |
| 安全调用 | `a?.b` | 空安全 › 安全调用操作符 · 第 806-807 页 | a 为 null 时整体得到 null，不抛异常；可以链式调用 |
| Elvis 操作符 | `a ?: b` | 空安全 › Elvis 操作符 · 第 807-808 页 | 左边为 null 时用右边 |
| 非空断言 | `a!!` | 空安全 › 非空断言操作符 · 第 808 页 | 为 null 时抛 NullPointerException |
| 可空值配合 let | `a?.let { }` | 空安全 · 第 810 页；作用域函数 › let · 第 1409 页 | 不为 null 才执行代码块 |

## 控制流程

| 语法 | 写法 | 文档位置 | 要点 |
|---|---|---|---|
| if 表达式 | `val x = if (c) a else b` | 条件与循环 › If 表达式 · 第 640 页 | if 有返回值，所以 Kotlin 没有三元运算符 |
| when 表达式 | `when (x) { 1 -> … else -> … }` | 条件与循环 › When 表达式与语句 · 第 641-644 页 | 相当于 switch，不需要 break；作表达式时要有 else |
| try-catch 表达式 | `val r = try { … } catch (e: E) { … }` | 习惯用法 › try-catch 表达式 · 第 571 页；异常 › 用 try-catch 处理异常 · 第 655 页 | try 有返回值，取 try 块或 catch 块最后一个表达式 |
| 返回与跳转 | `return` / `break` / `continue` | 返回与跳转 · 第 648 页 | return 从最直接包围它的函数返回 |
| lambda 中带标签返回 | `return@label` | 返回与跳转 › 返回到标签 · 第 648-650 页 | 只从 lambda 返回，不结束外层函数 |

## 函数与 lambda

| 语法 | 写法 | 文档位置 | 要点 |
|---|---|---|---|
| 函数声明 | `fun f(a: Int): Int` | 函数 · 第 761 页 | 参数写成“名字: 类型” |
| 默认实参 | `fun f(a: Int = 0)` | 函数 › 默认实参 · 第 762-763 页 | 不传就用默认值，减少重载 |
| 具名实参 | `f(icon = x)` | 函数 › 具名实参 · 第 763-764 页 | 按参数名传值，顺序可以变，可以跳过有默认值的参数 |
| 返回 Unit 的函数 | 不写返回类型 | 函数 › 返回 Unit 的函数 · 第 764-765 页 | Unit 相当于 Java 的 void |
| 单表达式函数 | `fun f() = 3` | 函数 › 单表达式函数 · 第 765 页 | 省略花括号和 return，返回类型可推断 |
| 顶层函数 | 写在类外面的 `fun` | 函数 › 函数作用域 · 第 767 页 | 不需要放进类里，导入后直接调用 |
| 挂起函数 | `suspend fun` | 组合挂起函数 · 第 1444 页；协程基础 · 第 1429 页 | 只能在协程或其它挂起函数里调用 |
| 函数类型 | `() -> Unit` | lambda 表达式 › 函数类型 · 第 771 页 | 函数也可以作为参数和变量 |
| lambda 表达式 | `{ x -> … }` | lambda 表达式 › Lambda 表达式语法 · 第 774 页 | 最后一个表达式是返回值 |
| 拖尾 lambda | `f(a) { … }` / `run { … }` | lambda 表达式 › 传递末尾的 lambda 表达式 · 第 774 页 | 最后一个参数是函数时，lambda 可以写在括号外；唯一参数时括号可省 |
| it 隐式参数 | `{ it > 0 }` | lambda 表达式 › it：单个参数的隐式名称 · 第 774-775 页 | 只有一个参数时可以不声明，用 it |
| SAM 转换 | `setOnClickListener { }` | 函数式（SAM）接口 › SAM 转换 · 第 688 页；在 Kotlin 中调用 Java › SAM 转换 · 第 922 页 | lambda 自动转换成只有一个抽象方法的接口 |
| 作用域函数 | `let` / `run` / `with` / `apply` / `also` | 作用域函数 · 第 1403-1404 页（对比表） | let/also 用 it，run/with/apply 用 this |
| let | `x?.let { it… }` | 作用域函数 › let · 第 1409 页 | 返回 lambda 的结果，常配合 ?. 处理非空值 |
| run | `x.run { 直接用成员 }` | 作用域函数 › run · 第 1404-1407 页 | 块里用 this（可省略）访问对象成员 |
| 扩展函数 | `fun View.makeGone()` | 扩展 › 扩展函数 · 第 694-695 页 | 不改原类，给它“添加”方法 |

## 类与对象

| 语法 | 写法 | 文档位置 | 要点 |
|---|---|---|---|
| 类与构造函数 | `class A(val x: Int)` | 类 · 第 670-674 页 | 主构造函数写在类名后 |
| 继承与覆盖 | `open` / `override` | 继承 › 覆盖方法 · 第 675-676 页；调用超类实现 · 第 677 页 | 类和成员默认 final，要 open 才能被继承 / 覆盖，覆盖必须写 override |
| 通用超类 Any | `Any` / `Any?` | 继承 · 第 675 页 | 所有类的共同超类 |
| 可见性修饰符 | `private` / `protected` / `internal` / `public` | 可见性修饰符 · 第 691-692 页 | 默认 public；private 只在类或文件内可见 |
| 数据类 | `data class` | 数据类 · 第 700-701 页 | 自动生成 equals / hashCode / toString / copy |
| 枚举类 | `enum class` | 枚举类 · 第 725 页 | 每个枚举常量都是对象 |
| 使用枚举常量 | `.name` / `values()` / `entries` | 枚举类 › 使用枚举常量 · 第 726-727 页 | name 是常量名字符串，values() 取所有常量 |
| 嵌套类与内部类 | `class` / `inner class` | 嵌套类 › 嵌套类与内部类 · 第 723 页 | inner 类持有外部类引用，可以访问外部成员 |
| 匿名内部类 | `object : 接口 { }` | 嵌套类 › 匿名内部类 · 第 724 页；对象表达式与对象声明 · 第 734-736 页 | 用对象表达式创建 |
| 对象声明（单例） | `object CacheUtil` | 对象表达式与对象声明 › 对象声明 · 第 734-735 页 | 单例，用“名字.成员”直接访问 |
| 伴生对象 | `companion object` | 对象表达式与对象声明 › 伴生对象 · 第 738-739 页 | 类级别的成员，相当于 Java 的 static |
| 限定的 this | `this@MainActivity` | this 表达式 › 限定的 this · 第 816 页 | 在 lambda 或内部类里指明是哪个外层对象 |
| 注解 | `@POST(...)` | 注解 · 第 824 页 | 给代码附加元数据，框架读取后生成代码 |
| 类引用 / Java 类 | `A::class.java` / `a.javaClass` | 在 Kotlin 中调用 Java › 获取 Java 类 · 第 920-921 页；反射 › 类引用 · 第 835 页 | 相当于 Java 的 A.class |

## 集合与标准库

| 语法 | 写法 | 文档位置 | 要点 |
|---|---|---|---|
| forEach | `list.forEach { }` | 迭代器 · 第 1331 页 | 逐个处理元素 |
| 过滤 | `filter { }` | 过滤集合 › 按谓词过滤 · 第 1350 页 | 返回满足条件的新列表 |
| 取单个元素（可空） | `firstOrNull { }` / `elementAtOrNull()` | 取单个元素 · 第 1362 页 | 找不到返回 null，不抛异常 |
| getOrNull | `list.getOrNull(i)` | 异常 · 第 662 页（作为安全替代提到） | 下标越界返回 null |
| forEachIndexed | `forEachIndexed { i, x -> }` | 文档没有单独讲；参考 迭代器 · 第 1331 页、lambda 表达式 · 第 774 页 | 遍历时同时拿到下标和元素 |

## 协程

| 语法 | 写法 | 文档位置 | 要点 |
|---|---|---|---|
| 启动协程 | `launch { }` | 协程基础 · 第 1428-1429 页 | 协程构建器，只能在 CoroutineScope 里调用 |
| 作用域 | `CoroutineScope` | 协程基础 · 第 1428-1430 页 | lifecycleScope 是 Android 提供的作用域（不在本文档里） |
| Job 与 join | `val job = launch { }` / `job.join()` | 协程基础 · 第 1432 页 | launch 返回 Job，join 挂起等待它结束 |
| 取消 | `job.cancel()` / `CancellationException` | 取消与超时 · 第 1435-1437 页 | 取消时挂起函数抛 CancellationException，不要吞掉它 |
| 超时 | `withTimeout` / `withTimeoutOrNull` | 取消与超时 › 超时 · 第 1440-1442 页 | 超时后 withTimeoutOrNull 返回 null 而不是抛异常 |

## 文档里没有的（Android / 第三方库）

`lifecycleScope`、`LiveData.postValue`、DataBinding 生成的属性（如 `mDatabind.ivScenePublic`）、Retrofit 注解（`@POST`、`@Field`）、`requireContext()` 等不是 Kotlin 语言本身的内容，文档里查不到。语法项写「文档：未收录（Android / 第三方库）」，再用自己的话解释。注解的写法本身可以引用「注解 · 第 824 页」。
