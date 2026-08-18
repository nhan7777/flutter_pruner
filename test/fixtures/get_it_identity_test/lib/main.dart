import 'a.dart' as a;
import 'b.dart' as b;
import 'models.dart';

a.Service fromA = a.Service();
b.Service fromB = b.Service();
Repository<User> users = Repository<User>();
Repository<Order> orders = Repository<Order>();
Outer<Repository<User>?> nested = Outer<Repository<User>?>();
Outer<Repository<User>> nonNullableNested = Outer<Repository<User>>();
dynamic dynamicValue;
Missing invalidValue;

T typeParameter<T>(T value) => value;

const constEmpty = '';
const constNamed = 'named:@,% <value>';
String runtimeName() => 'runtime';

void instanceNames() {
  consume(instanceName: constEmpty);
  consume(instanceName: constNamed);
  consume(instanceName: runtimeName());
}

void consume({String? instanceName}) {}
