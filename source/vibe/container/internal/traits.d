module vibe.container.internal.traits;

import std.traits;


/// Test if the type $(D DG) is a correct delegate for an opApply where the
/// key/index is of type $(D TKEY) and the value of type $(D TVALUE).
template isOpApplyDg(DG, TKEY, TVALUE) {
	import std.traits;
	static if (is(DG == delegate) && is(ReturnType!DG : int)) {
		private alias PTT = ParameterTypeTuple!(DG);
		private alias PSCT = ParameterStorageClassTuple!(DG);
		private alias STC = ParameterStorageClass;
		// Just a value
		static if (PTT.length == 1) {
			enum isOpApplyDg = (is(PTT[0] == TVALUE));
		} else static if (PTT.length == 2) {
			enum isOpApplyDg = (is(PTT[0] == TKEY))
				&& (is(PTT[1] == TVALUE));
		} else
			enum isOpApplyDg = false;
	} else {
		enum isOpApplyDg = false;
	}
}

unittest {
	static assert(isOpApplyDg!(int delegate(int, string), int, string));
	static assert(isOpApplyDg!(int delegate(ref int, ref string), int, string));
	static assert(isOpApplyDg!(int delegate(int, ref string), int, string));
	static assert(isOpApplyDg!(int delegate(ref int, string), int, string));
}
