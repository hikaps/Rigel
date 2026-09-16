package app.rigel.output

import app.rigel.cast.CastTarget

object DefaultOutputCapabilityResolver : OutputCapabilityResolver {
    override suspend fun profileFor(target: CastTarget): OutputMediaProfile =
        OutputMediaProfiles.familyDefault(target)

    override fun invalidate(target: CastTarget) = Unit
}
