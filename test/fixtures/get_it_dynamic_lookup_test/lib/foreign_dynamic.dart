dynamic foreign = Object();

void foreignDynamicLookup() {
  foreign.get<int>();
}

void foreignDynamicCallable() {
  foreign<int>();
}

void foreignDynamicStateMutation() {
  foreign.allowReassignment = true;
}
