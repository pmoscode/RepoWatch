import Synchronization

/// Thread-sicherer, änderbarer Wert, den mehrere Komponenten lesen, z. B. die Autor-Regeln,
/// die PR- und Actions-Modul beim Dekodieren nutzen. Änderungen in den Einstellungen greifen
/// so beim nächsten Sync, ohne Module neu zu erzeugen.
public final class SharedValue<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    public init(_ value: Value) {
        storage = Mutex(value)
    }

    public var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
